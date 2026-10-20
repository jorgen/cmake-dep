# cmake-dep

[![tests](https://github.com/jorgen/cmake-dep/actions/workflows/tests.yml/badge.svg)](https://github.com/jorgen/cmake-dep/actions/workflows/tests.yml)

A dependency manager for CMake projects, written in CMake. You declare dependencies by URL and
hash (or git commit); cmake-dep fetches them once per machine into a shared cache, resolves the
whole dependency graph to one copy of each package, and can build big dependencies like Qt once
and share the result. It needs nothing but CMake 3.18+.

- **Shared, safe cache**: every project, checkout and worktree uses `~/.cache/cmake-dep`.
  Downloads are hash-verified, crash-safe and locked against concurrent configures.
- **Mirrors**: LAN servers, file shares, Artifactory and friends are tried before upstream.
  Mirrors are content-addressed and hash-checked, so they don't need to be trusted. Air-gapped
  setups are supported, and write-back keeps a mirror filled.
- **Dependency graph and lockfile**: transitive dependencies are unified to one version per
  build, and `cmdep lock` records the resolved graph in `cmdep.lock`.
- **Git dependencies and patches**: pin a commit; apply patches without touching the shared copy.
- **Binary packages**: build QtBase once per machine (or once per team, through a signed binary
  mirror), and have it found at configure time with its real imported targets.
- **`cmdep` command**: `add`, `lock`, `tree`, `fetch`, `mirror`, `gc`, … — see [docs/cmdep.md](docs/cmdep.md).
- **Tested** on Linux, Windows (MSVC) and macOS, and on CMake 3.18 through 4.x.

## Quick Start

```cmake
# CMakeLists.txt
cmake_minimum_required(VERSION 3.18)
project(myproj LANGUAGES C CXX)

include(FetchContent)
FetchContent_Declare(cmake-dep
    GIT_REPOSITORY https://github.com/jorgen/cmake-dep.git
    GIT_TAG main)   # pin a commit in real projects
FetchContent_MakeAvailable(cmake-dep)
list(APPEND CMAKE_MODULE_PATH "${cmake-dep_SOURCE_DIR}/cmake")
include(CmDepMain)

CmDepFetch()                                            # reads cmdep-packages.cmake
CmDepAddPackage(libuv OPTIONS LIBUV_BUILD_TESTS=OFF)    # bundled, or find_package with -DMYPROJ_USE_SYSTEM_LIBUV=ON

add_executable(app main.cpp)
target_link_libraries(app PRIVATE uv_a)
```

```bash
# declare dependencies (writes cmdep-packages.cmake), then lock the graph
cmdep add libuv v1.51.0 https://github.com/libuv/libuv/archive/refs/tags/v1.51.0.tar.gz
cmdep add structify 1.0 https://github.com/jorgen/structify.git --git main
cmdep lock

cmake -B build && cmake --build build
```

`cmdep` lives in `bin/` of this repository (and is installed by `cmake --install`). The packages
file is plain CMake, so you can also write it by hand:

```cmake
# cmdep-packages.cmake
CmDepFetchPackage(libuv v1.51.0
    https://github.com/libuv/libuv/archive/refs/tags/v1.51.0.tar.gz
    SHA256=27e55cf7083913bfb6826ca78cde9de7647cded648d35f24163f2d31bb9f51cd)
```

For local development of cmake-dep itself, point FetchContent at a checkout:
`-DFETCHCONTENT_SOURCE_DIR_CMAKE-DEP=/path/to/cmake-dep`.

## Documentation

| Guide | Covers |
|---|---|
| [Declaring dependencies](docs/dependencies.md) | Archives, git commits, single files, patches, `LAZY`, overrides and system copies, optional dependencies, transitive dependencies, the lockfile |
| [Source cache and mirrors](docs/caching-and-mirrors.md) | Cache layout and safety, mirrors, authentication, write-back, cache maintenance, proxies/certificates, settings |
| [Binary packages](docs/binary-packages.md) | `CmDepBinaryPackage`, build keys, binary mirrors, signing, relocation, Debug/Release |
| [The `cmdep` command](docs/cmdep.md) | Every command and option |
| [`CmDepBuildExternal` (deprecated)](docs/build-external.md) | The old ExternalProject helpers and how to migrate |
| [Examples](examples) | A working project, a Qt app, config files, mirror servers (nginx, Artifactory, Nexus, S3), CI workflows |

## Declaring Dependencies

```cmake
CmDepFetchPackage(<name> <version> <url> <ALGO>=<hex> [PATCHES <file>...] [LAZY])
CmDepFetchGit(<name> <version> <repo> <commit> [SHA256=<hex>] [PATCHES <file>...] [LAZY])
CmDepFetchFile(<name> <version> <url> <destination name> <ALGO>=<hex>)
```

Each sets `<name>_SOURCE_DIR`, `<name>_VERSION`, `<name>_USE_SYSTEM` and `<name>_HASH`, and declares
override knobs named after your project (`MYPROJ_LIBUV_VERSION/_URL/_SHA256`,
`MYPROJ_USE_SYSTEM_LIBUV`), so a build can fetch something else or use a system copy without
editing the file. Details: [docs/dependencies.md](docs/dependencies.md).

### One copy per build, and the lockfile

When dependencies have dependencies (each project with its own packages file), cmake-dep makes
sure the build ends up with **one** copy of each package. The first declaration wins, normally
your root project's, and `CmDepAddPackage` adds each package once. `cmdep lock` resolves the
whole graph deliberately: root declarations win, otherwise the highest requested version, and
conflicting pins are an error. It writes `cmdep.lock`, which configures (and `cmdep fetch` /
`cmdep mirror`) then follow:

```bash
cmdep lock && cmdep tree
```

```
myproj (cmdep-packages.cmake)
|-- libA 1.0
|   `-- zlib 1.3 (asks for 1.2)
`-- libB 1.0
    `-- zlib 1.3
```

See [transitive dependencies](docs/dependencies.md#transitive-dependencies-one-copy-per-build).

## Using Fetched Dependencies: `CmDepAddPackage`

For the common "system copy via `find_package`, otherwise `add_subdirectory` the fetched
source" pattern, `CmDepAddPackage` does the branch for you -- reading the `MYPROJ_USE_SYSTEM_<DEP>`
toggle declared by `CmDepFetchPackage`:

```cmake
# system: find_package(structify CONFIG REQUIRED)
# bundled: add_subdirectory(... SYSTEM EXCLUDE_FROM_ALL)
CmDepAddPackage(structify CONFIG)

# force build knobs OFF/ON around the add_subdirectory (unset again afterwards)
CmDepAddPackage(llhttp CONFIG OPTIONS LLHTTP_BUILD_SHARED_LIBS=OFF LLHTTP_BUILD_STATIC_LIBS=ON)

# re-expose a header dir; skip the bundled build if the target already exists
CmDepAddPackage(vio CONFIG PUBLIC_INCLUDE src
    OPTIONS VIO_BUILD_TESTS=OFF VIO_BUILD_SHARED=OFF VIO_INSTALL=OFF)
```

Options:

| Option | Effect |
|---|---|
| `CONFIG` | Use `find_package(<pkg> CONFIG REQUIRED)` in system mode (default is plain `REQUIRED`) |
| `PACKAGE <pkg>` | `find_package` name override (default `<name>`) -- e.g. `CMakeRC` for package `cmakerc` |
| `OPTIONS <VAR=VAL>…` | Boolean cache knobs forced before `add_subdirectory`, unset after |
| `SUBDIR_ARGS <args>…` | Replaces the `add_subdirectory` args (default `SYSTEM`). `EXCLUDE_FROM_ALL` is applied on top of whatever you pass, unless `INCLUDE_IN_ALL` |
| `INCLUDE_IN_ALL` | Add the subdirectory to `ALL` -- opt out of the `EXCLUDE_FROM_ALL` default (see below) |
| `BINARY_DIR <dir>` | Binary dir for the `add_subdirectory` (default `${CMAKE_CURRENT_BINARY_DIR}/_cmdep/<name>`). Ignored if `SUBDIR_ARGS` already starts with a binary dir |
| `SKIP_IF_TARGET <tgt>` | In bundled mode, skip if `<tgt>` already exists. Rarely needed now: a package is added once per build anyway ([why](docs/dependencies.md#transitive-dependencies-one-copy-per-build)) |
| `PUBLIC_INCLUDE <dir>` | `target_include_directories(<name> PUBLIC ${<name>_SOURCE_DIR}/<dir>)` after the add |
| `NO_SYSTEM_FIND` | In system mode do nothing (the `find_package` is handled elsewhere) |

### `EXCLUDE_FROM_ALL` is the default

A bundled dependency is added `SYSTEM EXCLUDE_FROM_ALL`: it gets built because something links
it, not because it happens to sit in the tree. Without this, a consumer compiles and links every
target the dependency defines -- test binaries, benchmark tools, alternate library flavours -- and
pays for all of them on every build. Forcing the dependency's own `BUILD_TESTS`-style knobs off via
`OPTIONS` covers the targets a dependency thought to make optional; `EXCLUDE_FROM_ALL` covers the
rest.

Two consequences are worth knowing, because both are silent:

- **A target nothing links is never built, so it is never compile-checked either.** If a
  dependency's target is reached only indirectly -- a tool invoked from a custom command, a plugin
  loaded at runtime, or a library you are actively developing but have not linked yet -- give it an
  explicit dependency edge or pass `INCLUDE_IN_ALL`.
- **CMake also skips the subdirectory's `install()` rules.** If you relied on a bundled dependency
  installing its headers and libraries alongside the parent project, pass `INCLUDE_IN_ALL`. For most
  projects this is the desired behaviour and its absence was the bug: a static link against a
  bundled dependency has no reason to publish that dependency's headers into your install prefix.

`EXCLUDE_FROM_ALL` is applied independently of `SUBDIR_ARGS`, so overriding the `add_subdirectory`
arguments does not silently opt back into `ALL`, and passing `EXCLUDE_FROM_ALL` yourself is a no-op
rather than a duplicate argument.

For dependencies whose bundled path isn't a plain `add_subdirectory` (e.g. `include()`-based or
ExternalProject builds), branch by hand on the `${name}_USE_SYSTEM` signal (or query it with
`CmDepUseSystem(<name> out_var)`):

```cmake
if (cmakerc_USE_SYSTEM)
    find_package(CMakeRC CONFIG REQUIRED)
else ()
    include(${cmakerc_SOURCE_DIR}/CMakeRC.cmake)
endif ()
```

## The Source Cache and Mirrors

Every project, checkout and worktree on the machine shares one source cache
(`~/.cache/cmake-dep` by default), so a dependency is downloaded once per machine, not once per
checkout. Entries are hash-verified, crash-safe (completion stamp + atomic rename) and protected by
per-entry locks, so concurrent configures never race.

Before going to the upstream URL, cmake-dep can look for an archive on **mirrors**: a LAN server, a
file share, Artifactory, anything that serves files. Mirrors are content-addressed
(`<mirror>/sha256/<hex>`) and every byte is checked against the pinned hash, so a mirror doesn't
need to be trusted.

```cmake
# ~/.config/cmake-dep/config.cmake -- once per machine, applies to every project
set(CMDEP_MIRRORS "https://cmdep.lan.example.com,direct")    # leave out `direct` for air-gapped
set(CMDEP_MIRROR_PUSH "https://cmdep.lan.example.com")       # optional: fill the mirror on miss
```

```
lookup order:  extracted tree  >  local archive store  >  CMDEP_MIRRORS in order (`direct` = upstream URL)
```

Downloaded archives are kept in `~/.cache/cmake-dep/archives/sha256/<hex>`, which already has the
mirror layout: `rsync -a ~/.cache/cmake-dep/archives/ mirror:/srv/cmake-dep-mirror/` populates a
mirror, and so does `cmdep mirror <dir-or-url>`. `cmdep status` / `cmdep gc` / `cmdep verify`
keep the cache in check.

**Full guide: [docs/caching-and-mirrors.md](docs/caching-and-mirrors.md)**, covering cache layout,
mirror setup, authentication, populating mirrors, settings precedence, the security model and
troubleshooting. Ready-made config files, server setups (nginx, Artifactory, Nexus, S3) and CI
workflows are in [`examples/`](examples).

Because the cache is shared, treat entries as read-only: build out of source (`CmDepAddPackage`
does) and use [`PATCHES`](docs/dependencies.md#patches) rather than editing fetched sources.

## Binary Packages (Qt and other big dependencies)

Some dependencies are too expensive to compile in every build tree. `CmDepBinaryPackage` builds
one **once per machine** (at configure time, into `~/.cache/cmake-dep/bin/`), shares the installed
result between every checkout, worktree and build directory, and can download it from a team
**binary mirror** instead of building it at all:

```cmake
CmDepFetch()   # qtbase is listed in the packages file like any other source
CmDepBinaryPackage(qtbase
    CMAKE_ARGS   -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF
    FIND_PACKAGE Qt6 REQUIRED COMPONENTS Core Gui Widgets)
qt_standard_project_setup()                 # Qt6::moc etc. exist at configure time
```

```cmake
# developers                                          # CI, per platform
set(CMDEP_BINARY_MIRRORS "https://cmdep.lan")         set(CMDEP_BINARY_PUSH "https://cmdep.lan")
```

Packages are identified by a **build key**: a hash of the source, `CMAKE_ARGS`, compiler and
platform, configurations and dependencies. Absolute install paths in text files are rewritten so
packages survive the move into the cache and onto other machines. Unlike source archives, binaries
can't be checked against a pinned hash, so binary mirrors are a separate opt-in, and CI can
**sign** what it uploads (`CMDEP_BINARY_SIGNING_KEY`) so clients only accept packages from keys
they trust (`CMDEP_BINARY_TRUSTED_KEYS`). Mark the source `LAZY` and a machine that gets the binary
from a mirror never downloads the source at all.

Validated with real QtBase 6.8.1: built once (≈5 min, Core+Network on 4 cores), the next configure
in another build directory takes under a second, and a fresh machine gets a working, relocated Qt
from the mirror in about a second (AUTOMOC included).

**Full guide: [docs/binary-packages.md](docs/binary-packages.md)**, covering the build key,
`CMDEP_BINARY_PLATFORM` for matching keys across a team, mirrors, the trust model, relocation,
Debug/Release and troubleshooting. A Qt example is in [`examples/qt/`](examples/qt).

## API Reference

### Functions

| Function | Description |
|---|---|
| `CmDepFetch()` | Process the packages file (`CMDEP_PACKAGES_FILE`, default `cmdep-packages.cmake`); the first call also applies `cmdep.lock` |
| `CmDepFetchPackage(name version url hash [PATCHES …] [LAZY])` | Declare an archive dependency; auto-declares per-dep override + `USE_SYSTEM` knobs |
| `CmDepFetchGit(name version repo commit [SHA256=…] [PATCHES …] [LAZY])` | Declare a dependency pinned to a git commit |
| `CmDepFetchFile(name version url dest_name hash)` | Download a single file |
| `CmDepEnsureSource(name)` | Fetch a `LAZY` package's source now and set `<name>_SOURCE_DIR` |
| `CmDepAddPackage(name [CONFIG] [PACKAGE p] [OPTIONS …] [SUBDIR_ARGS …] [SKIP_IF_TARGET t] [PUBLIC_INCLUDE d] [BINARY_DIR d] [NO_SYSTEM_FIND] [INCLUDE_IN_ALL])` | Own the find_package-vs-add_subdirectory branch for a fetched dep. Bundled adds are `SYSTEM EXCLUDE_FROM_ALL` unless `INCLUDE_IN_ALL` |
| `CmDepUseSystem(name out_var)` | Query whether the system copy of `name` was requested |
| `CmDepFetchSetup(project_root packages_file)` | Standalone fetch (for `cmake -P` scripts) |
| `CmDepCacheDir(out_var)` | Resolve the source cache directory |
| `CmDepBinaryPackage(name [CMAKE_ARGS …] [FIND_PACKAGE …] [DEPENDS …] [KEY_VARS …] [CONFIGS …] [SOURCE_SUBDIR d] [GENERATOR g] [NO_PATH_REWRITE])` | Build a fetched dependency once per machine (or download it from a binary mirror) and `find_package` it from the shared cache. See [docs/binary-packages.md](docs/binary-packages.md) |

Deprecated (still working, see [docs/build-external.md](docs/build-external.md)): `CmDepBuildExternal`,
`CmDepTargetLinkLibrary`, `CmDepInstallDir`.

### The `cmdep` command

`add`, `hash`, `fetch`, `lock`, `tree`, `mirror`, `push-binary`, `keygen`, `status`, `gc`, `verify`,
`cache-dir`. See [docs/cmdep.md](docs/cmdep.md). The underlying `cmake -P` scripts
(`CmDepCli.cmake`, `CmDepFetchDependencies.cmake`, `CmDepMirror.cmake`, `CmDepBinaryPush.cmake`,
`CmDepCache.cmake`) can be called directly.

### Variables

| Variable | Default | Description |
|---|---|---|
| `CMDEP_PACKAGES_FILE` | `cmdep-packages.cmake` | Path to your packages file |
| `CMDEP_PROJECT` | `${PROJECT_NAME}` | Prefix (uppercased) for the auto-declared `<PREFIX>_<DEP>_*` / `<PREFIX>_USE_SYSTEM_<DEP>` knobs |

Machine-level settings. Each can be a CMake variable, an environment variable, or a line in the user
config file `~/.config/cmake-dep/config.cmake`, in that order of precedence
([details](docs/caching-and-mirrors.md#settings-reference)):

| Setting | Default | Description |
|---|---|---|
| `CMDEP_DIR` | `~/.cache/cmake-dep` | Local cache root (relative paths resolve against the project root) |
| `CMDEP_MIRRORS` | `direct` | Ordered sources, `,`- or `;`-separated: mirror URLs/paths and `direct` (the upstream URL) |
| `CMDEP_MIRROR_PUSH` | *(none)* | Mirror to upload newly downloaded archives to |
| `CMDEP_KEEP_ARCHIVES` | `ON` | Keep downloaded archives in `<cache>/archives/<algo>/<hex>` |
| `CMDEP_MIRROR_TIMEOUT` | `10` | Inactivity timeout (seconds) for mirror requests |
| `CMDEP_MIRROR_HTTPHEADER` | *(none)* | HTTP header sent to mirrors only (e.g. `Authorization: Bearer …`) |
| `CMDEP_BINARIES` | `prefer` | Binary packages: `prefer` (cache > mirrors > build), `require` (never build), `local` (never use mirrors) |
| `CMDEP_BINARY_MIRRORS` | *(none)* | Mirrors to download binary packages from |
| `CMDEP_BINARY_PUSH` | *(none)* | Mirror to upload locally built binary packages to |
| `CMDEP_BINARY_PLATFORM` | auto-detected | Replaces the platform part of the binary build key |
| `CMDEP_BINARY_JOBS` | logical cores | Parallel jobs when building a binary package |
| `CMDEP_BINARY_SIGNING_KEY` | *(none)* | Key that signs uploaded binary packages (CI) |
| `CMDEP_BINARY_TRUSTED_KEYS` | *(none)* | ssh `allowed_signers` file; only binaries signed by these keys are used |
| `CMDEP_LOCK_FILE` | `cmdep.lock` next to the packages file | Lockfile |
| `CMDEP_LOCKED` | `OFF` | Fail the configure if the lockfile is out of date |
| `CMDEP_TLS_CAINFO` | *(none)* | CA bundle for all downloads/uploads (corporate proxies) |

## Requirements

- CMake 3.18 or later (tested up to 4.x)
- Network access for first fetches, or a mirror
- Optional: `git` (git dependencies, patches), `ssh-keygen` from OpenSSH 8.1+ (signing binary
  packages), Ninja (recommended for binary package builds)

## Tests

```bash
cmake -P tests/CmDepFetchTest.cmake
```

Runs every suite and needs no internet access: archives are `file://` URLs, git repositories are
local, and HTTP mirrors are a small server on `127.0.0.1` ([`tests/mirror_server.py`](tests/mirror_server.py),
skipped without `python3`). The suites cover:
- fetching, the cache and mirrors;
- binary packages, including signing (needs a C compiler; signing needs `ssh-keygen`);
- cache maintenance and the `cmdep` command;
- patches, git dependencies, and the lockfile and transitive dependencies.

[CI](.github/workflows/tests.yml) runs them on Linux, Linux with CMake 3.18, Windows (MSVC) and
macOS.

## License

MIT
