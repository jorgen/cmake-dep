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
archive into `3rdparty/<name>-<version>/`, and sets two variables in the calling scope:

- `${name}_SOURCE_DIR` -- path to the extracted source
- `${name}_VERSION` -- the version string

### 2. Fetch during configure

Tell cmake-dep where your packages file is, then call `CmDepFetch()`:

```cmake
set(CMDEP_PACKAGES_FILE "${CMAKE_CURRENT_SOURCE_DIR}/CMake/3rdPartyPackages.cmake")
CmDepFetch()
```

Sources are downloaded into `${PROJECT_SOURCE_DIR}/3rdparty/` by default. Override with
`CMDEP_DIR`.

### 3. Use the fetched sources

After fetching, use the sources however your project needs -- `add_subdirectory`, ExternalProject,
or anything else:

```cmake
add_subdirectory(${libuv_SOURCE_DIR} "${CMAKE_CURRENT_BINARY_DIR}/libuv_build" SYSTEM)
```

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

This downloads all packages without running a full configure, which lets CI cache the `3rdparty/`
directory independently from the build.

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
| `CmDepFetchPackage(name version url hash)` | Download and extract an archive |
| `CmDepFetchFile(name version url dest_name hash)` | Download a single file |
| `CmDepBuildExternal(name version source_dir args targets)` | Build a dependency via ExternalProject |
| `CmDepTargetLinkLibrary(target scope targets...)` | Link against external and regular targets |
| `CmDepInstallDir(var name version)` | Get the install path for an external build |
| `CmDepFetchSetup(project_root packages_file)` | Standalone fetch (for `cmake -P` scripts) |

### Variables

| Variable | Default | Description |
|---|---|---|
| `CMDEP_PACKAGES_FILE` | *(required)* | Path to your packages definition file |
| `CMDEP_DIR` | `${PROJECT_SOURCE_DIR}/3rdparty` | Where to store fetched sources |

## Requirements

- CMake 3.18 or later
- A working internet connection for initial fetches (sources are cached in `3rdparty/`)

## License

MIT
