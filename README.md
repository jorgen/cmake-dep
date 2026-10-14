# cmake-dep

Reusable CMake helpers for fetching, building, and linking third-party dependencies. Handles
cross-platform concerns like Windows import libraries, RPATH, ccache, sanitizer flag propagation,
and position-independent code -- so your project doesn't have to.

## Quick Start

Add cmake-dep to your project via FetchContent:

```cmake
# CMakeLists.txt
cmake_minimum_required(VERSION 3.18)
project(my_project)

include(FetchContent)
FetchContent_Declare(cmake-dep
    GIT_REPOSITORY https://github.com/jorgen/cmake-dep.git
    GIT_TAG main
)
FetchContent_MakeAvailable(cmake-dep)
list(APPEND CMAKE_MODULE_PATH "${cmake-dep_SOURCE_DIR}/cmake")
include(CmDepMain)
```

For local development, point to a checkout on disk instead:

```cmake
FetchContent_Declare(cmake-dep
    SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../cmake-dep"
)
```

## Fetching Dependencies

### 1. Define your packages

Create a packages file (e.g. `CMake/3rdPartyPackages.cmake`) that lists what to download:

```cmake
CmDepFetchPackage(libuv v1.51.0
    https://github.com/libuv/libuv/archive/refs/tags/v1.51.0.tar.gz
    SHA256=27e55cf7083913bfb6826ca78cde9de7647cded648d35f24163f2d31bb9f51cd)

CmDepFetchPackage(doctest v2.4.12
    https://github.com/doctest/doctest/archive/refs/tags/v2.4.12.tar.gz
    SHA256=73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70)
```

Each call to `CmDepFetchPackage(name version url hash)` downloads and extracts the
archive into the shared cache (`~/.cache/cmake-dep/<name>-<version>-<hash12>/` by default,
see [The source cache](#the-source-cache)), and sets three variables in the calling scope:

- `${name}_SOURCE_DIR` -- path to the extracted source
- `${name}_VERSION` -- the version string (the effective, possibly-overridden one)
- `${name}_USE_SYSTEM` -- `ON`/`OFF`; whether a system copy was requested (see below)

Downloads happen at the first configure; later configures (in this or any other checkout) are
cache hits.

### Per-dependency overrides and system toggles

`CmDepFetchPackage` also auto-declares, for every dependency, a set of cache knobs
prefixed by your project name (uppercased). The prefix defaults to
`${PROJECT_NAME}` -- so a `project(myproj)` yields `MYPROJ_*` knobs with no extra
configuration. (It re-scopes correctly with `project()`, so a bundled sub-project
gets its own prefix. Override it with `CMDEP_PROJECT` if the desired prefix differs
from the project name, or in `cmake -P` script mode where no `project()` has run.)

For `CmDepFetchPackage(libuv v1.51.0 <url> SHA256=<hash>)` in project `myproj`:

| Knob | Effect |
|---|---|
| `MYPROJ_LIBUV_VERSION` / `MYPROJ_LIBUV_URL` / `MYPROJ_LIBUV_SHA256` | Override the fetched version / URL / hash (`-D…` wins over the file's defaults). The hash var is named after the algorithm in the `ALGO=HEX` token. |
| `MYPROJ_USE_SYSTEM_LIBUV` | `ON` skips the fetch entirely (consume a system copy instead). Default `OFF`. |

So a consumer can fetch a different version -- `-DMYPROJ_LIBUV_URL=… -DMYPROJ_LIBUV_SHA256=…` --
or opt out of the fetch -- `-DMYPROJ_USE_SYSTEM_LIBUV=ON` -- without editing the packages file.

### 2. Fetch during configure

Tell cmake-dep where your packages file is, then call `CmDepFetch()`:

```cmake
set(CMDEP_PACKAGES_FILE "${CMAKE_CURRENT_SOURCE_DIR}/CMake/3rdPartyPackages.cmake")
CmDepFetch()
```

Sources are downloaded into the shared cache by default. Override with `CMDEP_DIR`.

### The source cache and mirrors

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
mirror. `cmake/CmDepMirror.cmake` does the same from a packages file.

**Full guide: [docs/caching-and-mirrors.md](docs/caching-and-mirrors.md)**, covering cache layout,
mirror setup, authentication, populating mirrors, settings precedence, the security model and
troubleshooting. Ready-made config files, server setups (nginx, Artifactory, Nexus, S3) and CI
workflows are in [`examples/`](examples).

Because the cache is shared, treat entries as read-only: build out of source (`CmDepAddPackage`
and `CmDepBuildExternal` both do) and don't patch fetched sources in place.

### 3. Use the fetched sources

After fetching, use the sources however your project needs -- `add_subdirectory`, ExternalProject,
or anything else:

```cmake
add_subdirectory(${libuv_SOURCE_DIR} "${CMAKE_CURRENT_BINARY_DIR}/libuv_build" SYSTEM)
```

The sources are outside your project tree, so `add_subdirectory` needs an explicit binary
directory.

### 3b. Let cmake-dep own the find-vs-build branch

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
| `SKIP_IF_TARGET <tgt>` | In bundled mode, skip if `<tgt>` already exists (avoids duplicate-target clashes) |
| `PUBLIC_INCLUDE <dir>` | `target_include_directories(<name> PUBLIC ${<name>_SOURCE_DIR}/<dir>)` after the add |
| `NO_SYSTEM_FIND` | In system mode do nothing (the `find_package` is handled elsewhere) |

#### `EXCLUDE_FROM_ALL` is the default

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
can't be checked against a pinned hash, so binary mirrors are a separate opt-in and should only be
writable by trusted CI.

**Full guide: [docs/binary-packages.md](docs/binary-packages.md)**, covering the build key,
`CMDEP_BINARY_PLATFORM` for matching keys across a team, mirrors, the trust model, relocation,
Debug/Release and troubleshooting. A Qt example is in [`examples/qt/`](examples/qt).

## Building External Projects

For dependencies that need their own CMake configure/build/install cycle (e.g. LibreSSL),
use `CmDepBuildExternal`:

```cmake
CmDepInstallDir(OPENSSL_INSTALL_DIR openssl ${openssl_VERSION})
CmDepBuildExternal(openssl ${openssl_VERSION} ${openssl_SOURCE_DIR}
    "-DBUILD_SHARED_LIBS=OFF"       # extra CMake args (or "" for none)
    "OpenSSL::Crypto;OpenSSL::SSL"  # targets whose byproducts to track
)
```

This wraps CMake's `ExternalProject_Add` and automatically propagates:

- Build type (Debug/Release)
- C/C++ compiler and flags (including sanitizer flags)
- ccache launcher (if `CCACHE_PROGRAM` is set)
- `CMAKE_POSITION_INDEPENDENT_CODE`
- Generator and platform settings

The external project is installed into a per-package directory under the build tree
(`<build>/<name>_<version>_install`).

## Linking External Targets

`CmDepTargetLinkLibrary` links your target against dependencies that were built
with `CmDepBuildExternal`. It handles the details that `target_link_libraries` alone
doesn't cover for ExternalProject-built libraries:

```cmake
CmDepTargetLinkLibrary(my_app PRIVATE
    OpenSSL::Crypto OpenSSL::SSL
    some_regular_target
)
```

For each dependency it automatically:

- Links debug/release library variants correctly
- Sets up RPATH on Unix (so the binary finds the libraries at runtime)
- Uses import libraries on Windows for shared libraries
- Applies include directories and compile definitions from the target properties
- Adds build-order dependencies so the external project builds first

Regular targets (not built via ExternalProject) are passed through to `target_link_libraries`
unchanged, so you can mix both kinds in a single call.

### Target properties convention

Libraries built by `CmDepBuildExternal` store their paths and metadata as custom target
properties. These are the properties that `CmDepTargetLinkLibrary` reads:

| Property | Description |
|---|---|
| `CMDEP_EXTERNAL` | Set to TRUE to indicate this target was built externally |
| `CMDEP_TARGET` | The ExternalProject target name (for `add_dependencies`) |
| `CMDEP_LOCATION_DEBUG` | Path to the debug library |
| `CMDEP_LOCATION_RELEASE` | Path to the release library |
| `CMDEP_IMPLIB_DEBUG` | Path to the debug import lib (Windows shared libs) |
| `CMDEP_IMPLIB_RELEASE` | Path to the release import lib (Windows shared libs) |
| `CMDEP_INCLUDE_DIRS` | Include directories to propagate |
| `CMDEP_COMPILE_DEFS` | Compile definitions to propagate |

Your Find module or target setup code sets these properties. See
[VIO's Findlibressl.cmake](https://github.com/jorgen/vio/blob/master/CMake/FindPackage/libressl/Findlibressl.cmake)
for a complete example.

## Downloading Single Files

For dependencies that are a single file rather than an archive:

```cmake
CmDepFetchFile(my_header v1.0
    https://example.com/header.h
    header.h
    SHA256=abc123...)
```

## Standalone Fetch (CI / Pre-build)

Dependencies can be fetched outside of a full CMake configure, useful for CI caching. cmake-dep
provides `CmDepFetchSetup()` for this purpose.

Create a thin wrapper script in your project:

```cmake
# CMake/FetchDependencies.cmake
cmake_minimum_required(VERSION 3.18)

get_filename_component(_script_dir "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
get_filename_component(_project_root "${_script_dir}/.." ABSOLUTE)

# cmake-dep must be on disk (sibling checkout or from a prior configure)
include(${_project_root}/../cmake-dep/cmake/CmDepFetchDependencies.cmake)
CmDepFetchSetup("${_project_root}" "${_script_dir}/3rdPartyPackages.cmake")
```

Then run it from the command line:

```bash
cmake -P CMake/FetchDependencies.cmake
```

This downloads all packages without running a full configure, using the same fetch path,
cache, mirrors and locking as a configure -- so a pre-fetch is a cache hit at configure time. CI can
cache `~/.cache/cmake-dep/archives` (or set `CMDEP_DIR` to a cached path) independently from the
build; see [`examples/ci/github-actions.yml`](examples/ci/github-actions.yml).

## Populating a Mirror

```bash
cmake -DCMDEP_PACKAGES_FILE=CMake/3rdPartyPackages.cmake \
      -DCMDEP_MIRROR_OUT=/srv/cmake-dep-mirror \
      -P path/to/cmake-dep/cmake/CmDepMirror.cmake
```

Copies every archive the packages file pins into the mirror (a directory, `file://` URL, or an
HTTP(S) URL that accepts PUT), taking each from the local archive store when possible. See
[Populating a mirror](docs/caching-and-mirrors.md#populating-a-mirror).

## Complete Example

Putting it all together -- a project that fetches libuv and LibreSSL, builds LibreSSL as an
external project, and links everything:

```cmake
cmake_minimum_required(VERSION 3.18)
project(my_server LANGUAGES C CXX)

# --- cmake-dep setup ---
include(FetchContent)
FetchContent_Declare(cmake-dep
    GIT_REPOSITORY https://github.com/jorgen/cmake-dep.git
    GIT_TAG main
)
FetchContent_MakeAvailable(cmake-dep)
list(APPEND CMAKE_MODULE_PATH "${cmake-dep_SOURCE_DIR}/cmake")
include(CmDepMain)

# --- Fetch sources ---
set(CMDEP_PACKAGES_FILE "${CMAKE_CURRENT_SOURCE_DIR}/CMake/3rdPartyPackages.cmake")
CmDepFetch()

# --- Build dependencies ---
# libuv: built as a subdirectory (has its own CMakeLists.txt)
add_subdirectory(${libuv_SOURCE_DIR} "${CMAKE_BINARY_DIR}/libuv" SYSTEM)

# LibreSSL: built as an external project (separate configure/build/install)
CmDepInstallDir(LIBRESSL_INSTALL_DIR libressl ${libressl_VERSION})
list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/CMake/FindPackage/libressl")
find_package(libressl REQUIRED)
CmDepBuildExternal(libressl ${libressl_VERSION} ${libressl_SOURCE_DIR}
    "" "LibreSSL::Crypto;LibreSSL::SSL;LibreSSL::TLS")

# --- Your targets ---
add_executable(my_server main.cpp)
target_link_libraries(my_server PRIVATE uv_a)
CmDepTargetLinkLibrary(my_server PRIVATE LibreSSL::TLS LibreSSL::SSL LibreSSL::Crypto)
```

## API Reference

### Functions

| Function | Description |
|---|---|
| `CmDepFetch()` | Fetch all packages listed in `CMDEP_PACKAGES_FILE` |
| `CmDepFetchPackage(name version url hash)` | Download and extract an archive; auto-declare per-dep override + `USE_SYSTEM` knobs |
| `CmDepFetchFile(name version url dest_name hash)` | Download a single file |
| `CmDepAddPackage(name [CONFIG] [PACKAGE p] [OPTIONS …] [SUBDIR_ARGS …] [SKIP_IF_TARGET t] [PUBLIC_INCLUDE d] [BINARY_DIR d] [NO_SYSTEM_FIND] [INCLUDE_IN_ALL])` | Own the find_package-vs-add_subdirectory branch for a fetched dep. Bundled adds are `SYSTEM EXCLUDE_FROM_ALL` unless `INCLUDE_IN_ALL` |
| `CmDepUseSystem(name out_var)` | Query whether the system copy of `name` was requested |
| `CmDepBuildExternal(name version source_dir args targets)` | Build a dependency via ExternalProject |
| `CmDepTargetLinkLibrary(target scope targets...)` | Link against external and regular targets |
| `CmDepInstallDir(var name version)` | Get the install path for an external build |
| `CmDepFetchSetup(project_root packages_file)` | Standalone fetch (for `cmake -P` scripts) |
| `CmDepCacheDir(out_var)` | Resolve the source cache directory |
| `CmDepBinaryPackage(name [CMAKE_ARGS …] [FIND_PACKAGE …] [DEPENDS …] [KEY_VARS …] [CONFIGS …] [SOURCE_SUBDIR d] [GENERATOR g] [NO_PATH_REWRITE])` | Build a fetched dependency once per machine (or download it from a binary mirror) and `find_package` it from the shared cache. See [docs/binary-packages.md](docs/binary-packages.md) |

### Scripts (`cmake -P`)

| Script | Description |
|---|---|
| `cmake/CmDepFetchDependencies.cmake` | Fetch everything in `CMDEP_PACKAGES_FILE` without a configure |
| `cmake/CmDepMirror.cmake` | Copy everything in `CMDEP_PACKAGES_FILE` into the mirror `CMDEP_MIRROR_OUT` |
| `cmake/CmDepBinaryPush.cmake` | Upload the binary package `CMDEP_BINARY_ENTRY` from the local cache to `CMDEP_BINARY_PUSH` |

### Variables

| Variable | Default | Description |
|---|---|---|
| `CMDEP_PACKAGES_FILE` | *(required)* | Path to your packages definition file |
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

## Requirements

- CMake 3.18 or later
- A working internet connection for initial fetches, or a mirror (sources are cached in `~/.cache/cmake-dep`)

## Tests

```bash
cmake -P tests/CmDepFetchTest.cmake
```

Needs no internet access: it uses `file://` archives and, if `python3` is available, a small HTTP
mirror on `127.0.0.1` ([`tests/mirror_server.py`](tests/mirror_server.py)). It covers fresh
fetches, cache hits, recovery from partial entries, hash mismatches, overrides, locking and
concurrent fetchers, configure mode, the archive store, mirror fallback order (missing/corrupt/
unreachable mirrors), mirrors-only mode, write-back to directory and HTTP mirrors, mirror
authentication (and that it never reaches upstream), settings precedence, and `CmDepMirror.cmake`.
It also runs [`tests/CmDepBinaryTest.cmake`](tests/CmDepBinaryTest.cmake) (needs a C compiler).
That covers binary packages: local builds, cache hits across build directories, key changes,
pushing to and pulling from binary mirrors, `require`/`local` modes, corrupt mirror binaries,
install-path rewriting (including after download to a different path), Release+Debug builds,
`CmDepBinaryPush.cmake` and concurrent configures.

## License

MIT
