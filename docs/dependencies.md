# Declaring dependencies

A project lists its dependencies in a **packages file**, `cmdep-packages.cmake` in the project root
by convention. `CmDepFetch()` processes it at configure time; `cmdep` processes it without a
configure. This guide covers what can go in it, how a build with several projects that depend on
each other ends up with one copy of each package, and the lockfile.

- [The packages file](#the-packages-file)
- [Archives: `CmDepFetchPackage`](#archives-cmdepfetchpackage)
- [Git commits: `CmDepFetchGit`](#git-commits-cmdepfetchgit)
- [Single files: `CmDepFetchFile`](#single-files-cmdepfetchfile)
- [Patches](#patches)
- [Overrides and system copies](#overrides-and-system-copies)
- [Optional and test-only dependencies](#optional-and-test-only-dependencies)
- [Transitive dependencies: one copy per build](#transitive-dependencies-one-copy-per-build)
- [The lockfile](#the-lockfile)
- [Making your project a good dependency](#making-your-project-a-good-dependency)

## The packages file

```cmake
# cmdep-packages.cmake
CmDepFetchPackage(libuv v1.51.0
    https://github.com/libuv/libuv/archive/refs/tags/v1.51.0.tar.gz
    SHA256=27e55cf7083913bfb6826ca78cde9de7647cded648d35f24163f2d31bb9f51cd)

CmDepFetchGit(structify 1.0
    https://github.com/jorgen/structify.git
    b1145826ab4a06cbe32ae0c373a3161f74c48ac8
    SHA256=0746ec018614276fe16c14862b7953eabc5a95f808fb7d5d710c1cd1294cc5d1)
```

```cmake
# CMakeLists.txt
include(CmDepMain)
CmDepFetch()                      # reads cmdep-packages.cmake (or CMDEP_PACKAGES_FILE)
CmDepAddPackage(libuv OPTIONS LIBUV_BUILD_TESTS=OFF)
```

The easiest way to add an entry is `cmdep add`, which downloads the archive, computes the hash and
appends the declaration (see [the `cmdep` command](cmdep.md)):

```bash
cmdep add libuv v1.51.0 https://github.com/libuv/libuv/archive/refs/tags/v1.51.0.tar.gz
cmdep add structify 1.0 https://github.com/jorgen/structify.git --git main
```

A different file name works too: set `CMDEP_PACKAGES_FILE` before `CmDepFetch()`. The `cmdep`
command and the lock resolver also find `CMake/3rdPartyPackages.cmake`,
`cmake/3rdPartyPackages.cmake`, `cmake/packages.cmake` and `CMake/packages.cmake`.

Each declaration sets, in the scope that called `CmDepFetch()`:

| Variable | Meaning |
|---|---|
| `<name>_SOURCE_DIR` | Extracted (and patched) source in the shared cache |
| `<name>_VERSION` | The version in effect (after overrides and unification) |
| `<name>_USE_SYSTEM` | `ON` if a system copy was requested |
| `<name>_HASH` | `ALGO=HEX` of the archive in effect |

## Archives: `CmDepFetchPackage`

```cmake
CmDepFetchPackage(<name> <version> <url> <ALGO>=<hex> [PATCHES <file>...])
```

- `<version>` is a label used in the cache entry name, in lock resolution ("highest version wins")
  and in messages. It doesn't have to match the URL, but keeping them consistent avoids confusion.
- The hash is required and is what makes the shared cache and mirrors safe. Supported:
  `MD5`, `SHA1`, `SHA224`, `SHA256`, `SHA384`, `SHA512`, `SHA3_224`, `SHA3_256`, `SHA3_384`,
  `SHA3_512`. Use `SHA256` or stronger.
- Any archive format CMake can extract works (`.tar.gz`, `.tar.xz`, `.tar.bz2`, `.tar.zst`,
  `.zip`, `.7z`). A single top-level directory is stripped.

## Git commits: `CmDepFetchGit`

```cmake
CmDepFetchGit(<name> <version> <repository> <commit> [SHA256=<hex>] [PATCHES <file>...])
```

For projects without release archives, or when you need a specific commit.

- `<commit>` must be a full commit id. Tags and branches can move, so they are refused.
  `cmdep add <name> <version> <repo> --git <tag-or-branch>` resolves one for you.
- The content is `git archive --format=tar --prefix=source/ <commit>`. That depends only on the
  commit, so it can be hash-addressed like any archive.
- **With `SHA256=`** (written by `cmdep add --git`, or printed on first use), the dependency is an
  ordinary cached, mirrorable archive. Git is only needed if no mirror and no cache has it.
- **Without it**, the repository is cloned directly. Git verifies the commit id, so this is safe,
  but mirrors can't be used, and it fails if `direct` is not in `CMDEP_MIRRORS`. The first fetch
  prints the hash to pin.
- Needs `git` on `PATH`. Credentials, proxies and certificates come from git's own configuration.

## Single files: `CmDepFetchFile`

```cmake
CmDepFetchFile(<name> <version> <url> <destination name> <ALGO>=<hex>)
```

Downloads one file into `<cache>/<name>-<version>-<hash12>/<destination name>`. It goes through
the same cache, mirrors and verification.

## Patches

```cmake
CmDepFetchPackage(zlib 1.3.1 https://zlib.net/zlib-1.3.1.tar.gz SHA256=...
    PATCHES patches/zlib-0001-fix-cmake-install.patch
            patches/zlib-0002-no-shared.patch)
```

- Paths are relative to the packages file.
- Patches are unified diffs applied with `-p1` (git-style `a/` and `b/` prefixes; `git
  format-patch` output works), in order, using `git apply`, or `patch` if git is missing.
- The patched tree is a **separate cache entry**, `<name>-<version>-<hash12>-p<patchhash8>`. The
  shared original is never modified, and changing a patch gives a new entry.
- A patch that doesn't apply fails the configure, with git's message and nothing left behind.

## Overrides and system copies

Every declaration creates cache variables named after the project (`project(myproj)` gives
`MYPROJ_…`; set `CMDEP_PROJECT` to choose another prefix):

| Knob | Effect |
|---|---|
| `MYPROJ_LIBUV_VERSION`, `MYPROJ_LIBUV_URL`, `MYPROJ_LIBUV_SHA256` | Fetch something else without editing the file (`-D…` wins) |
| `MYPROJ_STRUCTIFY_GIT_URL`, `MYPROJ_STRUCTIFY_COMMIT`, `MYPROJ_STRUCTIFY_SHA256` | Same for git dependencies |
| `MYPROJ_USE_SYSTEM_LIBUV=ON` | Don't fetch; `CmDepAddPackage` then uses `find_package` |

The root project's `USE_SYSTEM` knobs also work for **transitive** packages that are in the
lockfile: `-DMYPROJ_USE_SYSTEM_ZLIB=ON` switches zlib to the system copy for every project in the
build.

## Optional and test-only dependencies

A packages file is CMake, so declarations can be conditional:

```cmake
if (MYPROJ_BUILD_TESTS)
    CmDepFetchPackage(doctest v2.4.12 ... SHA256=...)
endif ()
```

Use this for test and benchmark tools: when your project is a dependency of something else, its
`MYPROJ_BUILD_TESTS` is normally off and doctest isn't fetched.

## Transitive dependencies: one copy per build

C++ can't link two versions of one library into one program, so a build needs exactly one copy of
each package, however many projects ask for it. cmake-dep keeps a **registry** for the whole
configure:

1. The first declaration of a name wins. That is normally the root project's: its `CmDepFetch()`
   runs before any dependency is added. Otherwise it's the lockfile's choice (below).
2. A dependency that declares the same name later (its own `CmDepFetch()` runs during
   `add_subdirectory`) gets the registered copy: same source directory, same version. If it asked
   for something else you see:
   ```
   -- cmake-dep: zlib: libB asks for 1.3; using 1.2 (from libA) so the build has one copy
   ```
3. `CmDepAddPackage(zlib)` adds a package once per build. A second call in another project is a
   no-op, because the targets already exist. No more duplicate-target errors or `SKIP_IF_TARGET`
   workarounds.
4. `CmDepUseSystem` and `CmDepAddPackage` follow the registry, so whoever resolved a package
   decides system-vs-bundled for everyone.

Without a lockfile, "first declaration wins" depends on the order projects are added. That is
deterministic but arbitrary. The lockfile replaces it with a deliberate choice.

## The lockfile

```bash
cmdep lock          # resolve the whole graph, write cmdep.lock next to the packages file
cmdep tree          # show it
cmdep lock --check  # CI: fail if cmdep.lock is missing or out of date
```

```
myproj (cmdep-packages.cmake)
|-- libA 1.0
|   |-- common 1.0
|   `-- zlib 1.3 (asks for 1.2)
`-- libB 1.0
    |-- pat 1.0
    `-- zlib 1.3
```

### How resolution works

`cmdep lock` reads your packages file, fetches each package it declares, and reads *that*
package's packages file (by the file-name convention above), repeating until nothing changes. For
each package name:

1. **A root declaration always wins.** Declaring a package yourself is how you settle any question.
2. Otherwise, the **highest version** requested by any resolved package wins, comparing the
   numeric part of the version label (`v1.51.0` gives `1.51.0`).
3. Two requests for the **same version with different hashes** are an error. You decide by
   declaring the package in the root.
4. Only requests from the version of a package that was *selected* count. If libA 2.0 replaces
   libA 1.0, libA 1.0's requirements disappear.

Requests that lost are listed in the `cmdep lock` output and in `cmdep tree` (`asks for …`).
Large version differences (a different major version) are *not* rejected automatically. Check
the list after updating.

Declarations guarded by options are evaluated with those options unset, the same way the
packages are normally configured as dependencies. To include your own test dependencies, pass
the option: `cmdep lock -DMYPROJ_BUILD_TESTS=ON`. Root declarations not in the lock are fine at
configure time; you get a note suggesting `cmdep lock`.

### The file

`cmdep.lock` is plain CMake, meant to be committed:

```cmake
CmDepLocked(zlib
    VERSION [==[1.3]==]
    URL [==[https://zlib.net/zlib-1.3.tar.gz]==]
    HASH SHA256=...
    DECLARED_BY libB
    DECLARED_IN [==[CMake/3rdPartyPackages.cmake]==]
    REQUESTED_BY [==[libA=1.2]==] [==[libB=1.3]==])
```

Packages appear declarer-first, so each package's declarer (and its patches) is available before
it. Regenerate it with `cmdep lock` rather than editing it.

### At configure time

The first `CmDepFetch()` of the build (the root):

1. loads `cmdep.lock` (or `CMDEP_LOCK_FILE`);
2. processes the root packages file, comparing each declaration with the lock;
3. fetches every *transitive* package in the lock and registers it, applying its patches
   relative to the packages file that declared it.

When a dependency's own `CmDepFetch()` runs later, every package it declares is already in the
registry, so the whole build uses the locked versions.

| Situation | Behaviour |
|---|---|
| Root declaration matches the lock | Silent |
| Root declaration differs from the lock (you edited the packages file) | Warning: run `cmdep lock`. The packages file is used |
| Same, with `-DCMDEP_LOCKED=ON` | Configure fails (use this in CI) |
| `-D…_URL/_SHA256` override of a root declaration | Note; the override is used |
| Root declaration not in the lock | Note; it is used |

`cmdep fetch` and `cmdep mirror` also use the lock, so they cover the whole graph: CI caching
and mirror population include transitive packages.

## Making your project a good dependency

To let projects that use yours resolve its dependencies:

- **Ship a packages file at a conventional path**: `cmdep-packages.cmake` in the root, or one of
  the other names listed above.
- **Keep it declarative**: only `CmDepFetch*` calls and `if()` on your own options. It is evaluated
  in script mode during `cmdep lock`.
- **Guard test-only dependencies** with an option that is off when you're not the top-level
  project.
- **Use `CmDepFetch()` and `CmDepAddPackage()`** in your `CMakeLists.txt`, so that when you are a
  dependency, the registry gives you the build's copy.
- **Name packages consistently** with the rest of the ecosystem. The registry treats the same name
  as the same package.
