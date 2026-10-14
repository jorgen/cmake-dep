# Binary packages

Some dependencies are too big to build as part of every build tree. QtBase takes anywhere from 15
minutes to an hour to compile, and rebuilding it for every checkout, worktree and build directory
is not workable. `CmDepBinaryPackage` builds such a dependency **once**, installs it into the shared
cache, and lets every project on the machine use the installed result. With a binary mirror, it is
built once for the **whole team**.

- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [The build key](#the-build-key)
- [Binary mirrors](#binary-mirrors)
- [Trust](#trust)
- [Relocation](#relocation)
- [Configurations (Debug/Release)](#configurations-debugrelease)
- [Reference](#reference)
- [Troubleshooting](#troubleshooting)

It builds on the source cache and mirrors described in
[caching-and-mirrors.md](caching-and-mirrors.md). Read that first if you haven't.

## Quick start

```cmake
# packages file: the source is fetched (and mirrored) as usual
CmDepFetchPackage(qtbase v6.8.1
    https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtbase-everywhere-src-6.8.1.tar.xz
    SHA256=<hash of the archive>)
```

```cmake
# CMakeLists.txt
CmDepFetch()

CmDepBinaryPackage(qtbase
    CMAKE_ARGS   -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF
    FIND_PACKAGE Qt6 REQUIRED COMPONENTS Core Gui Widgets)

set(CMAKE_AUTOMOC ON)                      # works: Qt6::moc exists at configure time
add_executable(app main.cpp)
target_link_libraries(app PRIVATE Qt6::Widgets)
```

- **First configure on a machine:** QtBase is built and installed into
  `~/.cache/cmake-dep/bin/qtbase-v6.8.1-<key12>/`. Configure prints progress, and full logs are
  kept.
- **Every later configure,** in any checkout, worktree or build directory with the same
  configuration, is a cache hit taking milliseconds.
- **With a team binary mirror,** even the first configure just downloads the installed Qt.

A complete example is in [`examples/qt/`](../examples/qt).

## How it works

`CmDepBinaryPackage(<name> ...)` computes a **build key** (next section). Then it looks for the
installed prefix in this order:

```
1. local cache      ~/.cache/cmake-dep/bin/<name>-<version>-<key12>/       (stamped = complete)
2. binary mirrors   <mirror>/bin/<key>.tar.zst   (each CMDEP_BINARY_MIRRORS entry, in order)
3. build it         at configure time, into the local cache                (unless CMDEP_BINARIES=require)
```

After a local build, the package is uploaded to `CMDEP_BINARY_PUSH` if that is set. Finally:

- `<name>_BINARY_PREFIX` and `<name>_BINARY_KEY` are set;
- the prefix is appended to `CMAKE_PREFIX_PATH`;
- `find_package(<FIND_PACKAGE args> PATHS <prefix> NO_DEFAULT_PATH)` runs, so you get the package's
  real imported targets with all their usage requirements.

**Why at configure time?** A package like Qt has to be found at configure time. AUTOMOC/AUTOUIC
need `Qt6::moc`/`Qt6::uic`, and consumers need the imported targets. `ExternalProject` builds at
build time, which is too late (that is why `CmDepBuildExternal` needs its `CMDEP_LOCATION_*`
workaround). The cost is one long configure per machine and configuration. After that it is free.

The local build uses the same safety mechanisms as source fetches:

- a per-entry lock, so two configures needing the same package build it once while the other waits;
- assembly in `.tmp/` with a completion stamp and atomic rename, so an interrupted build never
  leaves a half-installed prefix;
- full configure/build/install logs, kept on failure.

`<PREFIX>_USE_SYSTEM_<NAME>=ON` (declared by `CmDepFetchPackage`) skips all of this, and
`FIND_PACKAGE` runs against the system instead.

## The build key

A source archive is identified by the hash pinned in the packages file. A binary has no pinned
hash, because what identifies it is everything that went into building it. cmake-dep hashes all of
these into the build key:

| Input | Why |
|---|---|
| Source archive hash | Different source → different binary |
| `CMAKE_ARGS` (in order) | Features and options |
| Platform: OS, CPU, C/C++ compiler ID **and version**, glibc version (Linux, native builds) | ABI and runtime compatibility. Replaceable, see below |
| Configurations (`Release`, `Debug`, …) | Debug and release builds differ in ABI on MSVC |
| `CMAKE_TOOLCHAIN_FILE` (content hash), `CMAKE_MSVC_RUNTIME_LIBRARY`, `CMAKE_OSX_ARCHITECTURES`, `CMAKE_OSX_DEPLOYMENT_TARGET`, `CMAKE_OSX_SYSROOT`/`CMAKE_SYSROOT` (SDK name), `CMAKE_POSITION_INDEPENDENT_CODE` | Toolchain settings that are also forwarded to the build |
| `DEPENDS` packages' build keys | If OpenSSL changes, a Qt built against it must change too |
| `KEY_VARS` variables | Anything else you know matters |
| `SOURCE_SUBDIR`, binary format version | Bookkeeping |

The full list of inputs is stored in each package as `.cmake-dep-binary.txt`. When you expected a
hit and got a build, compare that file between the two packages to see which input differs.

**Not in the key:** the generator, build parallelism, compiler *paths* (the compiler identity is in
the platform part), and the parent project's own `CMAKE_CXX_FLAGS`. If a flag affects the
dependency's ABI, pass it through `CMAKE_ARGS` (then it is in the key) or list the variable in
`KEY_VARS`.

### Making keys match across a team: `CMDEP_BINARY_PLATFORM`

The auto-detected platform is deliberately conservative: GCC 13.2.0 and 13.3.0 get different keys,
and so do glibc 2.35 and 2.39. If your team builds in one Docker image or on one standard toolchain,
replace the auto-detected platform with a tag you control:

```cmake
# ~/.config/cmake-dep/config.cmake, or set by the CI image
set(CMDEP_BINARY_PLATFORM "linux-x86_64-ubuntu24.04-gcc13")
```

Bump the tag when the image changes in a way that matters. Everything else in the table above stays
in the key.

## Binary mirrors

Binary mirrors use the same servers as source mirrors (see
[mirror server setups](../examples/mirror-servers)), under a `bin/` directory:

```
<mirror>/
├── sha256/<hex>                  source archives (CMDEP_MIRRORS)
└── bin/
    ├── <key>.tar.zst             installed prefix, zstd-compressed tar
    └── <key>.tar.zst.sha256      checksum, uploaded last = "upload complete"
```

```cmake
set(CMDEP_BINARY_MIRRORS "https://cmdep.lan.example.com")   # where to look (',' or ';' separated)
set(CMDEP_BINARY_PUSH    "https://cmdep.lan.example.com")   # CI only: upload what it built
```

- **Download:** the `.sha256` file is fetched first (missing means not on this mirror), then the
  tarball, which is checked against it. The package's recorded key must match the requested key.
  Anything else is reported and the next mirror (or a local build) is used. Unreachable mirrors are
  skipped for the rest of the run, as for sources.
- **Upload:** after a local build, the prefix is packed and uploaded with the same mechanisms as
  source write-back: an atomic copy for directories, HTTP PUT for servers, credentials from netrc or
  `CMDEP_MIRROR_HTTPHEADER`. A failed upload only warns.
- **Sharing an existing build:** `cmake/CmDepBinaryPush.cmake` uploads a package that is already in
  your local cache:
  ```bash
  cmake -DCMDEP_BINARY_ENTRY=$HOME/.cache/cmake-dep/bin/qtbase-v6.8.1-1a2b3c4d5e6f \
        -DCMDEP_BINARY_PUSH=https://cmdep.lan.example.com \
        -P path/to/cmake-dep/cmake/CmDepBinaryPush.cmake
  ```

`CMDEP_BINARIES` controls the policy:

| Value | Behaviour |
|---|---|
| `prefer` *(default)* | Local cache, then binary mirrors, then build locally |
| `require` | Local cache, then binary mirrors, otherwise **fail** (lists the build inputs). For people who'd rather know than wait an hour |
| `local` | Never consult binary mirrors; local cache or local build only |

A typical setup: a CI job per supported platform configures the project with `CMDEP_BINARY_PUSH`
set, so the team mirror always has binaries for the current pins
([`examples/ci/binary-packages.yml`](../examples/ci/binary-packages.yml)). Developers have
`CMDEP_BINARY_MIRRORS` and get Qt in the time it takes to download it.

## Trust

This is the one place where binary packages differ fundamentally from sources.

A source archive is checked against a hash pinned in your repository, so a source mirror cannot get
anything into your build that you didn't pin. **A binary package cannot be checked that way.** Its
contents are whatever the machine that built it produced. The `.sha256` file only detects corrupt
or truncated transfers. It does not prove where the binary came from. Whoever can write to a
binary mirror can put code into every build that downloads from it.

So:

- **Binary mirrors are opt-in and separate.** `CMDEP_BINARY_MIRRORS` is its own setting. Pointing
  `CMDEP_MIRRORS` at a server never makes you trust its binaries.
- **Restrict who can push.** Give `CMDEP_BINARY_PUSH` credentials to CI only (the nginx example
  protects PUT with a password). Don't let developer machines push unless you trust them all.
- **Serve over HTTPS** (or a trusted file share), so the connection can't be tampered with.
- **Packages you build yourself are always trusted.** `CMDEP_BINARIES=local` uses only those.

Signing (CI signs each package's build inputs and checksum; clients pin the public key) is planned
but not implemented yet.

## Relocation

A binary package is installed into a temporary directory, then moved into the cache, and later
extracted at a different path on other machines. Many packages write their install prefix into
text files: CMake package files, pkg-config `.pc` files, qmake `.prl`/`.pri` files.

cmake-dep rewrites those paths:

- **After a local build,** occurrences of the temporary install prefix in text files (`.cmake`,
  `.pc`, `.prl`, `.pri`, `.la`, `.conf`, `.cfg`, `.ini`, `.json`, `.txt`, `.sh`, `.bat`, `.cmd`,
  `.py`, `.pl`, `.qmake`) are replaced with the final cache path. The manifest records that path.
- **After a download from a mirror,** the recorded path is replaced with wherever the package lands
  on this machine.

Run with `--log-level=VERBOSE` to see which files were rewritten.

**Binary files are never modified.** A library that hard-codes its install prefix in machine code
(rather than finding its files relative to itself) is not relocatable, and cmake-dep can't fix
that. Qt 6 is relocatable by default. Use relative `RPATH`s (`$ORIGIN`, `@loader_path`) for shared
libraries.

To make an unexpected absolute path an error instead, pass `NO_PATH_REWRITE`: the configure fails
and lists the offending files. That suits packages you maintain yourself and want to keep clean.

## Configurations (Debug/Release)

| Parent project | Configurations built | Generator used for the dependency |
|---|---|---|
| Single-config, `CMAKE_BUILD_TYPE=Debug` | `Debug` | Ninja if found, else the parent's |
| Single-config, anything else | `Release` | Ninja if found, else the parent's |
| Multi-config (Visual Studio, Xcode, Ninja Multi-Config) | `Release;Debug` | Ninja Multi-Config if found, else the parent's |
| `CONFIGS a b …` given | exactly those | Ninja Multi-Config if found (several configs) |

All configurations are installed into **one prefix**, which suits packages that install
per-configuration files side by side (Qt with its `d` debug suffix on Windows, any CMake project
with `CMAKE_DEBUG_POSTFIX`). With a single-config generator and several configurations, each gets
its own build directory and they are installed one after another. Override the generator with
`GENERATOR`.

On Windows, build both configurations for MSVC projects that build Debug: mixing a release Qt with
a debug application mixes C runtimes.

## Reference

```cmake
CmDepBinaryPackage(<name>
    [CMAKE_ARGS <arg>...]            # arguments for the dependency's configure (part of the key)
    [FIND_PACKAGE <args>...]         # find_package(<args> PATHS <prefix> NO_DEFAULT_PATH)
    [DEPENDS <binary package>...]    # earlier CmDepBinaryPackage()s to build against (keys chained)
    [KEY_VARS <variable>...]         # extra variables whose values must change the key
    [CONFIGS <config>...]            # default: see "Configurations"
    [SOURCE_SUBDIR <dir>]            # CMakeLists.txt is in a subdirectory of the source
    [GENERATOR <generator>]          # default: Ninja / Ninja Multi-Config if found, else the parent's
    [NO_PATH_REWRITE])               # fail instead of rewriting absolute install paths
```

Requires an earlier `CmDepFetchPackage(<name> ...)` (normally via `CmDepFetch()`). `FIND_PACKAGE`
arguments are passed through unchanged, so include `REQUIRED` if you want it.

**Sets:** `<name>_BINARY_PREFIX` (installed prefix), `<name>_BINARY_KEY` (full build key). Appends
the prefix to `CMAKE_PREFIX_PATH`.

**Settings** (CMake variable > environment > config file, as for mirrors):

| Setting | Default | Meaning |
|---|---|---|
| `CMDEP_BINARIES` | `prefer` | `prefer`, `require` or `local` (see [Binary mirrors](#binary-mirrors)) |
| `CMDEP_BINARY_MIRRORS` | *(none)* | Mirrors to download binary packages from, in order |
| `CMDEP_BINARY_PUSH` | *(none)* | Mirror to upload locally built packages to |
| `CMDEP_BINARY_PLATFORM` | auto-detected | Replaces the platform part of the build key |
| `CMDEP_BINARY_JOBS` | `$CMAKE_BUILD_PARALLEL_LEVEL`, else logical cores | Parallel jobs for local builds |

`CMDEP_MIRROR_TIMEOUT` and `CMDEP_MIRROR_HTTPHEADER` apply to binary mirrors too.

**Scripts:** `cmake/CmDepBinaryPush.cmake` (`CMDEP_BINARY_ENTRY`, `CMDEP_BINARY_PUSH`).

## Troubleshooting

**"building it now" when you expected a hit.** The key differs. Compare
`~/.cache/cmake-dep/bin/<entry>/.cmake-dep-binary.txt` between the package you have and the one
you expected, or with what CI pushed. Usual suspects: compiler patch version or glibc (set
`CMDEP_BINARY_PLATFORM`), a `CMAKE_ARGS` difference, Debug vs Release.

**A local build failed.** The error shows the end of the log and the full log's path
(`~/.cache/cmake-dep/.tmp/bin-<entry>/configure-*.log`, `build-*.log`, `install-*.log`). The work
directory is kept until the next attempt.

**The package can't find its files after the move.** It hard-codes its prefix somewhere cmake-dep
doesn't rewrite: a binary file, or an unusual text-file extension. Check
`--log-level=VERBOSE` output for what was rewritten, and fix the package to use relative paths.

**Windows: the application can't find the DLLs.** The prefix's `bin/` is not on `PATH`. Copy the
DLLs next to the executable (e.g. `windeployqt`, or a post-build `copy_if_different` of
`$<TARGET_RUNTIME_DLLS:app>`), or set `VS_DEBUGGER_ENVIRONMENT`.

**Disk usage.** Each distinct key is a full installed prefix. Delete old entries under
`~/.cache/cmake-dep/bin/` when you no longer need them. Anything currently in use is rebuilt or
re-downloaded on the next configure.
