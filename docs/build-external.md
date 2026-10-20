# `CmDepBuildExternal` (deprecated)

> **Deprecated.** Use [`CmDepBinaryPackage`](binary-packages.md) instead. `CmDepBuildExternal`,
> `CmDepTargetLinkLibrary` and `CmDepInstallDir` keep working unchanged and print no warnings.
> They are no longer developed, and new projects shouldn't use them.

## Why

`CmDepBuildExternal` wraps `ExternalProject_Add`. That has three structural problems which
`CmDepBinaryPackage` doesn't have:

| | `CmDepBuildExternal` | `CmDepBinaryPackage` |
|---|---|---|
| When it builds | At **build** time | At **configure** time, once |
| Where the result lives | Each build tree (`<build>/<name>_<version>_install`) | The shared cache: one build per machine and configuration |
| How consumers see it | Hand-written `CMDEP_LOCATION_*` / `CMDEP_IMPLIB_*` properties, read by `CmDepTargetLinkLibrary` | `find_package` against the installed prefix: the package's real imported targets and usage requirements |
| Sharing | None | Binary mirrors, signed uploads |
| Rebuilt when | You wipe a build tree, add a worktree, switch build type… | The build key changes |

The build-time model is also why a Find module and `CmDepTargetLinkLibrary` were needed: nothing
exists yet at configure time, so targets have to be described by hand.

## Migrating

Before:

```cmake
CmDepInstallDir(LIBRESSL_INSTALL_DIR libressl ${libressl_VERSION})
list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/CMake/FindPackage/libressl")
find_package(libressl REQUIRED)                       # sets CMDEP_LOCATION_* etc.
CmDepBuildExternal(libressl ${libressl_VERSION} ${libressl_SOURCE_DIR}
    "-DLIBRESSL_TESTS=OFF" "LibreSSL::Crypto;LibreSSL::SSL;LibreSSL::TLS")

add_executable(my_server main.cpp)
CmDepTargetLinkLibrary(my_server PRIVATE LibreSSL::TLS LibreSSL::SSL LibreSSL::Crypto)
```

After:

```cmake
CmDepBinaryPackage(libressl
    CMAKE_ARGS   -DLIBRESSL_TESTS=OFF
    FIND_PACKAGE LibreSSL REQUIRED)                   # the package's own config file

add_executable(my_server main.cpp)
target_link_libraries(my_server PRIVATE LibreSSL::TLS)
```

Steps:

1. Replace the `CmDepInstallDir` + `CmDepBuildExternal` pair with one `CmDepBinaryPackage`. Move the
   extra CMake arguments to `CMAKE_ARGS`.
2. Point `FIND_PACKAGE` at the dependency's own installed CMake config: `<Name>Config.cmake` under
   `lib/cmake/`. If the dependency doesn't install one, keep a small Find module that looks under
   `${<name>_BINARY_PREFIX}` and creates imported targets, instead of setting `CMDEP_*` properties.
3. Replace `CmDepTargetLinkLibrary(...)` with plain `target_link_libraries(...)`. The imported
   targets carry their include directories, definitions and Debug/Release locations.
4. Delete the `CMDEP_LOCATION_*` / `CMDEP_IMPLIB_*` / `CMDEP_EXTERNAL` property code.
5. On Windows with shared libraries, copy the DLLs next to your executables (see
   [binary packages: troubleshooting](binary-packages.md#troubleshooting)). They now live in the
   cache, not your build tree.

Behaviour that changes:

- **The first configure takes longer**, because the dependency builds then. Every later configure
  and build is faster.
- **Debug and Release:** `CmDepBuildExternal` built whichever configuration you built.
  `CmDepBinaryPackage` builds `CMAKE_BUILD_TYPE`, or `Release;Debug` for multi-config generators,
  up front.
- **Compiler flags:** `CmDepBuildExternal` forwarded `CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS` (e.g.
  sanitizers). `CmDepBinaryPackage` forwards the toolchain, but not your project's flags. Pass the
  ones that matter in `CMAKE_ARGS`, so they are also part of the build key.

## Reference (unchanged)

### `CmDepBuildExternal(name version source_dir cmake_args build_targets)`

Wraps `ExternalProject_Add` and propagates the build type (Debug/Release), C/C++ compiler and
flags, the ccache launcher (`CCACHE_PROGRAM`), `CMAKE_POSITION_INDEPENDENT_CODE`, and the generator
and platform. Installs into `<build>/<name>_<version>_install`.

```cmake
CmDepInstallDir(OPENSSL_INSTALL_DIR openssl ${openssl_VERSION})
CmDepBuildExternal(openssl ${openssl_VERSION} ${openssl_SOURCE_DIR}
    "-DBUILD_SHARED_LIBS=OFF"       # extra CMake args (or "" for none)
    "OpenSSL::Crypto;OpenSSL::SSL"  # targets whose byproducts to track
)
```

### `CmDepTargetLinkLibrary(target scope targets...)`

Links against targets built with `CmDepBuildExternal`:

- links debug/release library variants;
- sets up `BUILD_RPATH` on Unix;
- uses import libraries on Windows for shared libraries;
- applies include directories and compile definitions;
- adds build-order dependencies on the external project.

Other targets are passed through to `target_link_libraries` unchanged.

### `CmDepInstallDir(var name version)`

Sets `var` to `<build>/<name>_<version>_install`.

### Target properties read by `CmDepTargetLinkLibrary`

| Property | Description |
|---|---|
| `CMDEP_EXTERNAL` | TRUE for targets built externally |
| `CMDEP_TARGET` | The ExternalProject target name (for `add_dependencies`) |
| `CMDEP_LOCATION_DEBUG` / `CMDEP_LOCATION_RELEASE` | Library paths |
| `CMDEP_IMPLIB_DEBUG` / `CMDEP_IMPLIB_RELEASE` | Import libraries (Windows shared libraries) |
| `CMDEP_INCLUDE_DIRS` | Include directories to propagate |
| `CMDEP_COMPILE_DEFS` | Compile definitions to propagate |
