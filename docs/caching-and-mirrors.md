# Source cache and mirrors

cmake-dep downloads every dependency once per machine into a shared cache. It can also be told to
look for archives on a **mirror** first: a LAN server, a file share, an Artifactory repository or
anything else that can serve files. Only after that does it try the upstream URL. This guide covers
how that works, how to set it up, and how to keep a mirror populated.

- [How a fetch works](#how-a-fetch-works)
- [Quick recipes](#quick-recipes)
- [The local cache](#the-local-cache)
- [Mirrors](#mirrors)
- [Populating a mirror](#populating-a-mirror)
- [Settings reference](#settings-reference)
- [Security model](#security-model)
- [Troubleshooting](#troubleshooting)

See also the ready-to-use files in [`examples/`](../examples): config files, server setups and CI
workflows.

## How a fetch works

Every dependency in a packages file carries a hash:

```cmake
CmDepFetchPackage(libuv v1.51.0
    https://github.com/libuv/libuv/archive/refs/tags/v1.51.0.tar.gz
    SHA256=27e55cf7083913bfb6826ca78cde9de7647cded648d35f24163f2d31bb9f51cd)
```

That hash names the archive. When cmake-dep needs `libuv`, it walks this chain and stops at the
first hit:

```
 1. extracted source tree   ~/.cache/cmake-dep/libuv-v1.51.0-27e55cf70839/      (done, no lock, no I/O)
 2. local archive store     ~/.cache/cmake-dep/archives/sha256/27e55cf7…        (extract it)
 3. each CMDEP_MIRRORS entry, in order:
      a mirror              <mirror>/sha256/27e55cf7…                           (download, verify, extract)
      direct                https://github.com/libuv/libuv/archive/…            (download, verify, extract)
```

After a successful network download (step 3):

- the archive is kept in the local archive store (`CMDEP_KEEP_ARCHIVES`, on by default), and
- if `CMDEP_MIRROR_PUSH` is set, the archive is uploaded to that mirror (*write-back*).

Every downloaded byte is checked against the hash before it is used. A source that returns
something else is reported and skipped, and the next source is tried.

The default `CMDEP_MIRRORS` is just `direct`. With nothing configured, cmake-dep behaves as it
always did: it downloads from the URL in the packages file.

## Quick recipes

**Use a LAN mirror, fall back to the internet**

```bash
# once per machine, in ~/.config/cmake-dep/config.cmake:
set(CMDEP_MIRRORS "https://cmdep.lan.example.com,direct")
```

**Air-gapped / "nothing leaves the network"**: leave out `direct`:

```cmake
set(CMDEP_MIRRORS "https://cmdep.lan.example.com,/mnt/share/cmake-dep")
```

**Let developers fill the mirror automatically**: whatever is missing gets downloaded upstream
once, then pushed:

```cmake
set(CMDEP_MIRRORS "https://cmdep.lan.example.com,direct")
set(CMDEP_MIRROR_PUSH "https://cmdep.lan.example.com")   # needs a server that accepts PUT
```

**Seed a mirror from your own machine** (you have already configured the projects):

```bash
rsync -a ~/.cache/cmake-dep/archives/ mirror-host:/srv/cmake-dep-mirror/
```

**Seed a mirror from a packages file**:

```bash
cmake -DCMDEP_PACKAGES_FILE=CMake/3rdPartyPackages.cmake \
      -DCMDEP_MIRROR_OUT=/srv/cmake-dep-mirror \
      -P path/to/cmake-dep/cmake/CmDepMirror.cmake
```

**One-off override on the command line**:

```bash
cmake -B build -DCMDEP_MIRRORS=/mnt/usb/cmake-dep-mirror,direct
CMDEP_MIRRORS=/mnt/usb/cmake-dep-mirror cmake -B build      # or via the environment
```

**Per-project vendor directory instead of the shared cache**:

```bash
cmake -B build -DCMDEP_DIR=3rdparty      # relative to the project root
```

## The local cache

```
~/.cache/cmake-dep/
├── libuv-v1.51.0-27e55cf70839/        extracted source tree (what ${libuv_SOURCE_DIR} points to)
│   ├── .cmake-dep-complete            completion stamp
│   └── …
├── doctest-v2.4.12-73381c7aa4de/
├── archives/
│   └── sha256/
│       ├── 27e55cf7083913bf…          the libuv tarball, named by its hash
│       └── 73381c7aa4dee704…
├── .locks/                            one lock file per entry
└── .tmp/                              work area for fetches in progress
```

**Location.** The first of: `CMDEP_DIR` (CMake variable, environment variable, or config file),
`$XDG_CACHE_HOME/cmake-dep`, `~/.cache/cmake-dep` (`%LOCALAPPDATA%\cmake-dep` on Windows). A
relative `CMDEP_DIR` is resolved against the project root.

**Entry names** are `<name>-<version>-<hash12>`. Two projects that pin the same version to
different archives, or a `-D<PREFIX>_<DEP>_URL/_SHA256` override, get separate entries and never
overwrite each other.

**Crash safety.** An entry is assembled under `.tmp/`, the `.cmake-dep-complete` stamp is written
last, and then the directory is renamed into place in one step. A directory without a stamp is
treated as an interrupted fetch: it is deleted and fetched again. If the stamp is somehow missing
right after a fetch, configure fails instead of retrying, so there is no fetch loop.

**Concurrency.** Changes to an entry happen under a per-entry `file(LOCK)`. Two configures that need
the same dependency at the same time (two worktrees, parallel CI jobs) don't race: one fetches, the
other prints `waiting for another process to finish fetching...` and then uses the result. Complete
entries are read without locking.

**Archive store.** Keeping the archives costs disk space roughly equal to the compressed size of
your dependencies. In return:

- a deleted or damaged source tree is rebuilt with no network access;
- `archives/` already has the mirror layout, so copying it *is* populating a mirror;
- CI can cache just `archives/`, which is smaller than the extracted trees.

Turn it off with `CMDEP_KEEP_ARCHIVES=OFF`.

**Treat entries as read-only.** They are shared by every project on the machine. Build out of
source (`CmDepAddPackage` and `CmDepBuildExternal` both do this) and don't patch fetched sources in
place.

**Clearing the cache.** Delete the directory, or any entry in it. Deleting while no configure is
running is always safe.

## Mirrors

### Layout

A mirror is a directory of archives named by hash:

```
<mirror>/
└── sha256/
    ├── 27e55cf7083913bfb6826ca78cde9de7647cded648d35f24163f2d31bb9f51cd
    └── 73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70
```

The subdirectory is the hash algorithm in lowercase (`sha256`, `sha512`, `md5`, …), matching the
`ALGO=` in the packages file. There is no index or metadata: the file at
`<mirror>/<algo>/<hex>` is the whole contract. Any static file server works, and so does any
directory.

Because lookups go by hash, one mirror serves every project and every upstream host. It doesn't
matter that one package came from GitHub and another from a vendor's FTP server.

### Kinds of mirror entries

`CMDEP_MIRRORS` is an ordered list. Separate entries with `,` (works everywhere, including shells)
or with `;` (a normal CMake list). Each entry is one of:

| Entry | Example | Notes |
|---|---|---|
| `direct` | `direct` | The package's own URL from the packages file |
| HTTP(S) URL | `https://cmdep.lan.example.com` | GET `<url>/sha256/<hex>`. A 404 (or any HTTP error) counts as "not here" |
| `file://` URL | `file:///mnt/share/cmake-dep` | Local or network file system |
| Plain path | `/mnt/share/cmake-dep`, `D:/mirror` | Same as `file://` |

Order matters: put the fastest source first. Typical choices:

```
/mnt/fast-local-disk/cmake-dep,https://cmdep.lan,direct     # local > LAN > internet
https://cmdep.lan                                           # LAN only (air-gapped)
https://cmdep.office-a.lan,https://cmdep.office-b.lan,direct  # several sites
```

### What happens when a mirror misbehaves

| Situation | Behaviour |
|---|---|
| Mirror doesn't have the archive (missing file, HTTP 404/401/403) | Quietly tries the next source (shown with `--log-level=VERBOSE`) |
| Mirror unreachable (connection refused, DNS failure, timeout) | One `STATUS` line, then the mirror is **skipped for the rest of that CMake run**, so 30 dependencies don't each wait for the timeout |
| Mirror serves the wrong bytes (hash mismatch) | `STATUS` line naming the mirror, tries the next source |
| No source has it | Configure fails and lists every source with its reason. If `direct` was not in the list, the message says so |

Example failure:

```
CMake Error at …/CmDepFetch.cmake (message):
  cmake-dep: could not fetch libuv (SHA256=27e55cf7…) from any source:
    https://cmdep.lan.example.com: HTTP response code said error
    /mnt/share/cmake-dep: not present
    ('direct' is not in CMDEP_MIRRORS, so the upstream URL https://github.com/… was not tried)
```

The inactivity timeout for mirrors is `CMDEP_MIRROR_TIMEOUT` seconds (default 10). It does not
apply to `direct`, which uses CMake's normal download behaviour.

### Authentication

Two options, both used **only for mirrors and never sent to upstream URLs**:

- **`~/.netrc`**. Mirror requests are made with `NETRC OPTIONAL`, so a matching entry is used
  automatically:
  ```
  machine cmdep.lan.example.com
  login ci-bot
  password s3cret
  ```
- **`CMDEP_MIRROR_HTTPHEADER`**. One HTTP header sent with every mirror request and push:
  ```bash
  export CMDEP_MIRROR_HTTPHEADER="Authorization: Bearer $MIRROR_TOKEN"
  export CMDEP_MIRROR_HTTPHEADER="X-JFrog-Art-Api: $ARTIFACTORY_KEY"
  ```

Prefer the environment or netrc for secrets. A `-D` value would end up in `CMakeCache.txt`.

## Populating a mirror

There are three ways, and they combine freely.

### 1. Copy the archive store

Every machine that has configured a project has the archives in mirror layout:

```bash
rsync -a ~/.cache/cmake-dep/archives/ mirror-host:/srv/cmake-dep-mirror/
aws s3 sync ~/.cache/cmake-dep/archives/ s3://my-bucket/cmake-dep/
```

Files never change once written (the name *is* the content hash), so incremental copies are always
correct, and copying from several machines into one mirror is fine.

### 2. `CmDepMirror.cmake`: from a packages file

```bash
cmake -DCMDEP_PACKAGES_FILE=CMake/3rdPartyPackages.cmake \
      -DCMDEP_MIRROR_OUT=/srv/cmake-dep-mirror \
      -P path/to/cmake-dep/cmake/CmDepMirror.cmake
```

- `CMDEP_MIRROR_OUT` may be a directory, a `file://` URL, or an `http(s)://` URL that accepts PUT.
- Each archive is taken from the first source that has it: the local archive store, then
  `CMDEP_MIRRORS` (default `direct`). On a machine that has already built the project, this needs
  no network.
- Archives already in a local output directory are verified and skipped.
- Run it once per project (or packages file) to build one mirror for many projects. See
  [`examples/scripts/populate-mirror.sh`](../examples/scripts/populate-mirror.sh).
- `-DCMDEP_PROJECT=<prefix>` makes `-D<PREFIX>_<DEP>_URL/_SHA256` overrides apply here too.

### 3. Write-back: `CMDEP_MIRROR_PUSH`

```cmake
set(CMDEP_MIRRORS "https://cmdep.lan.example.com,direct")
set(CMDEP_MIRROR_PUSH "https://cmdep.lan.example.com")
```

When an archive had to come from somewhere other than the push target (usually `direct`), it is
uploaded after it passes the hash check. The first person or CI job to need a new version fills the
mirror for everyone else.

- **Directory / `file://` target**: the archive is copied to a temporary name and renamed, so
  readers never see a partial file. Existing files are left alone.
- **HTTP(S) target**: `PUT <url>/sha256/<hex>`, sending the same netrc / header credentials. Works
  with nginx WebDAV, Artifactory and Nexus generic/raw repositories, and similar servers.
- Archives taken from the local store are not pushed (no network fetch happened).
- **A failed push never fails the configure.** You get a warning and the build continues.

A common split: developers have read-only `CMDEP_MIRRORS`, and only CI holds push credentials.

## Settings reference

All settings are resolved in this order; the first that is set wins, and an empty value means "use
the default":

1. **CMake variable**: `-DCMDEP_MIRRORS=…`, or `set()` in `CMakeLists.txt` before `CmDepFetch()`
2. **Environment variable** of the same name
3. **User config file**: the first of `$CMDEP_CONFIG`, `$XDG_CONFIG_HOME/cmake-dep/config.cmake`,
   `~/.config/cmake-dep/config.cmake` (`%APPDATA%\cmake-dep\config.cmake` on Windows)
4. Built-in default

| Setting | Default | Meaning |
|---|---|---|
| `CMDEP_DIR` | `~/.cache/cmake-dep` | Local cache root. Relative paths resolve against the project root |
| `CMDEP_MIRRORS` | `direct` | Ordered sources (`,` or `;` separated). Leave out `direct` for mirrors-only |
| `CMDEP_MIRROR_PUSH` | *(none)* | Mirror to upload newly downloaded archives to (directory, `file://`, or HTTP(S) with PUT) |
| `CMDEP_KEEP_ARCHIVES` | `ON` | Keep downloaded archives in `<cache>/archives/<algo>/<hex>` |
| `CMDEP_MIRROR_TIMEOUT` | `10` | Inactivity timeout in seconds for mirror downloads and pushes |
| `CMDEP_MIRROR_HTTPHEADER` | *(none)* | One HTTP header (e.g. `Authorization: Bearer …`) for mirror requests only |
| `CMDEP_MIRROR_OUT` | *(none)* | `CmDepMirror.cmake` only: the mirror to populate |

The config file is plain CMake, read once per run. Use plain `set()` without `CACHE`:

```cmake
# ~/.config/cmake-dep/config.cmake
set(CMDEP_MIRRORS "https://cmdep.lan.example.com,direct")
```

Machine-level settings belong in the config file or the environment, not in a project's
`CMakeLists.txt`: the mirror is a property of where you build, not of what you build. A project
*may* set defaults (`set(CMDEP_MIRRORS …)` before `CmDepFetch()`), but those then override
everyone's config file.

## Security model

- **The hash in the packages file is the trust anchor.** Every byte from every source (mirror,
  archive store, upstream) is verified against it before use. A malicious or stale mirror can make
  a fetch *fail*, but cannot get different code into your build.
- So mirrors can be plain HTTP on a LAN, shared directories, or third-party caches, without any
  trust in them.
- The archive store is re-verified on use; a corrupt copy is deleted and fetched again.
- Mirror credentials (`CMDEP_MIRROR_HTTPHEADER`, netrc) are sent only to mirrors, never to `direct`
  URLs.
- What you *do* need to protect is the packages file and any `-D…_SHA256` overrides. Whoever
  controls the hash controls what gets built.

## Troubleshooting

**See which source each archive came from.** Each extracted entry's stamp records it:

```bash
cat ~/.cache/cmake-dep/libuv-v1.51.0-27e55cf70839/.cmake-dep-complete
# name=libuv  version=v1.51.0  url=https://…  hash=SHA256=…  source=https://cmdep.lan.example.com
```

**See every mirror miss.** `cmake -B build --log-level=VERBOSE`.

**"waiting for another process to finish fetching..." never ends.** Another CMake process holds
the lock. If no CMake is running, the operating system has already released the lock. Locks don't
outlive processes. Look for a hung configure (`ps aux | grep cmake`).

**Mirror changes don't seem to apply.** An entry that is already extracted is a cache hit, so no
source is consulted at all. That's intended. To test a mirror, point `CMDEP_DIR` at an empty
directory: `cmake -B /tmp/b -DCMDEP_DIR=/tmp/empty-cache`.

**`could not push to mirror`.** The fetch itself succeeded. Check write permissions (directory
mirrors), PUT support and credentials (HTTP mirrors). `curl -T somefile <mirror>/sha256/test` is a
quick PUT check.

**Private S3 bucket / CDN returns 403.** That counts as "not here" (same as 404), and the next
source is tried. Either make the mirror readable or put an authenticating proxy in front of it.
