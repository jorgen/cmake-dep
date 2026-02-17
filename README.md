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
CmDepFetch3rdParty_Package(libuv v1.51.0
    https://github.com/libuv/libuv/archive/refs/tags/v1.51.0.tar.gz
    SHA256=27e55cf7083913bfb6826ca78cde9de7647cded648d35f24163f2d31bb9f51cd)

CmDepFetch3rdParty_Package(doctest v2.4.12
    https://github.com/doctest/doctest/archive/refs/tags/v2.4.12.tar.gz
    SHA256=73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70)
```

Each call to `CmDepFetch3rdParty_Package(name version url hash)` downloads and extracts the
archive into `3rdparty/<name>-<version>/`, and sets two variables in the calling scope:

- `${name}_SOURCE_DIR` -- path to the extracted source
- `${name}_VERSION` -- the version string

### 2. Fetch during configure

Tell cmake-dep where your packages file is, then call `CmDepFetch3rdParty()`:

```cmake
set(CMDEP_3RD_PARTY_PACKAGES_FILE "${CMAKE_CURRENT_SOURCE_DIR}/CMake/3rdPartyPackages.cmake")
CmDepFetch3rdParty()
```

Sources are downloaded into `${PROJECT_SOURCE_DIR}/3rdparty/` by default. Override with
`CMDEP_3RD_PARTY_DIR` or the legacy `POINTS_3RD_PARTY_DIR` variable.

### 3. Use the fetched sources

After fetching, use the sources however your project needs -- `add_subdirectory`, ExternalProject,
or anything else:

```cmake
add_subdirectory(${libuv_SOURCE_DIR} "${CMAKE_CURRENT_BINARY_DIR}/libuv_build" SYSTEM)
```

## Building External Projects

For dependencies that need their own CMake configure/build/install cycle (e.g. LibreSSL),
use `CmDepBuildExternalCMake`:

```cmake
CmDepGetPackageInstallDir(OPENSSL_INSTALL_DIR openssl ${openssl_VERSION})
CmDepBuildExternalCMake(openssl ${openssl_VERSION} ${openssl_SOURCE_DIR}
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

`CmDepBuildExternalTargetLinkLibrary` links your target against dependencies that were built
with `CmDepBuildExternalCMake`. It handles the details that `target_link_libraries` alone
doesn't cover for ExternalProject-built libraries:

```cmake
CmDepBuildExternalTargetLinkLibrary(my_app PRIVATE
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

Libraries built by `CmDepBuildExternalCMake` store their paths and metadata as custom target
properties. These are the properties that `CmDepBuildExternalTargetLinkLibrary` reads:

| Property | Description |
|---|---|
| `BUILD_EXTERNAL` | Set to TRUE to indicate this target was built externally |
| `BUILD_EXTERNAL_TARGET` | The ExternalProject target name (for `add_dependencies`) |
| `BUILD_EXTERNAL_IMPORTED_LOCATION_DEBUG` | Path to the debug library |
| `BUILD_EXTERNAL_IMPORTED_LOCATION_RELEASE` | Path to the release library |
| `BUILD_EXTERNAL_IMPORTED_IMPLIB_DEBUG` | Path to the debug import lib (Windows shared libs) |
| `BUILD_EXTERNAL_IMPORTED_IMPLIB_RELEASE` | Path to the release import lib (Windows shared libs) |
| `BUILD_EXTERNAL_INTERFACE_INCLUDE_DIRECTORIES` | Include directories to propagate |
| `BUILD_EXTERNAL_INTERFACE_COMPILE_DEFINITIONS` | Compile definitions to propagate |

Your Find module or target setup code sets these properties. See
[VIO's Findlibressl.cmake](https://github.com/jorgen/vio/blob/master/CMake/FindPackage/libressl/Findlibressl.cmake)
for a complete example.

## Downloading Single Files

For dependencies that are a single file rather than an archive:

```cmake
CmDepFetch3rdParty_File(my_header v1.0
    https://example.com/header.h
    header.h
    SHA256=abc123...)
```

## Standalone Fetch (CI / Pre-build)

Dependencies can be fetched outside of a full CMake configure, useful for CI caching.
`CmDepFetchDependencies.cmake` can be run directly as a script -- no wrapper needed:

```bash
cmake -DCMDEP_PACKAGES_FILE=CMake/3rdPartyPackages.cmake \
      -P 3rdparty/cmake-dep/cmake/CmDepFetchDependencies.cmake
```

This downloads all packages without running a full configure, which lets CI cache the `3rdparty/`
directory independently from the build.

Optional variables:

| Variable | Default | Description |
|---|---|---|
| `CMDEP_PACKAGES_FILE` | *(required)* | Path to your packages definition file |
| `CMDEP_PROJECT_ROOT` | Current working directory | Project root for resolving `3rdparty/` |
| `CMDEP_3RD_PARTY_DIR` | `${CMDEP_PROJECT_ROOT}/3rdparty` | Override 3rdparty directory |

A typical CI workflow (cmake-dep is fetched into `3rdparty/` by the first configure, then cached):

```yaml
- name: Cache 3rdparty
  uses: actions/cache@v4
  with:
    path: 3rdparty
    key: 3rdparty-${{ hashFiles('CMake/3rdPartyPackages.cmake') }}

- name: Fetch cmake-dep
  if: ${{ !hashFiles('3rdparty/cmake-dep/cmake/CmDepMain.cmake') }}
  run: git clone --depth 1 https://github.com/jorgen/cmake-dep.git 3rdparty/cmake-dep

- name: Fetch dependencies
  run: cmake -DCMDEP_PACKAGES_FILE=CMake/3rdPartyPackages.cmake -P 3rdparty/cmake-dep/cmake/CmDepFetchDependencies.cmake
```

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
set(CMDEP_3RD_PARTY_PACKAGES_FILE "${CMAKE_CURRENT_SOURCE_DIR}/CMake/3rdPartyPackages.cmake")
CmDepFetch3rdParty()

# --- Build dependencies ---
# libuv: built as a subdirectory (has its own CMakeLists.txt)
add_subdirectory(${libuv_SOURCE_DIR} "${CMAKE_BINARY_DIR}/libuv" SYSTEM)

# LibreSSL: built as an external project (separate configure/build/install)
CmDepGetPackageInstallDir(LIBRESSL_INSTALL_DIR libressl ${libressl_VERSION})
list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/CMake/FindPackage/libressl")
find_package(libressl REQUIRED)
CmDepBuildExternalCMake(libressl ${libressl_VERSION} ${libressl_SOURCE_DIR}
    "" "LibreSSL::Crypto;LibreSSL::SSL;LibreSSL::TLS")

# --- Your targets ---
add_executable(my_server main.cpp)
target_link_libraries(my_server PRIVATE uv_a)
CmDepBuildExternalTargetLinkLibrary(my_server PRIVATE LibreSSL::TLS LibreSSL::SSL LibreSSL::Crypto)
```

## API Reference

### Functions

| Function | Description |
|---|---|
| `CmDepFetch3rdParty()` | Fetch all packages listed in `CMDEP_3RD_PARTY_PACKAGES_FILE` |
| `CmDepFetch3rdParty_Package(name version url hash)` | Download and extract an archive |
| `CmDepFetch3rdParty_File(name version url dest_name hash)` | Download a single file |
| `CmDepBuildExternalCMake(name version source_dir args targets)` | Build a dependency via ExternalProject |
| `CmDepBuildExternalTargetLinkLibrary(target scope targets...)` | Link against external and regular targets |
| `CmDepGetPackageInstallDir(var name version)` | Get the install path for an external build |
| `CmDepFetchDependenciesSetup(project_root packages_file)` | Standalone fetch (for `cmake -P` scripts) |

### Variables

| Variable | Default | Description |
|---|---|---|
| `CMDEP_3RD_PARTY_PACKAGES_FILE` | *(required)* | Path to your packages definition file |
| `CMDEP_3RD_PARTY_DIR` | `${PROJECT_SOURCE_DIR}/3rdparty` | Where to store fetched sources |
| `POINTS_3RD_PARTY_DIR` | *(unset)* | Legacy alias for `CMDEP_3RD_PARTY_DIR` |

## Requirements

- CMake 3.18 or later
- A working internet connection for initial fetches (sources are cached in `3rdparty/`)

## License

MIT
