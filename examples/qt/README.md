# Qt example

A Qt Widgets "hello" application. QtBase comes from cmake-dep as a **binary package**.

```bash
# 1. pin the QtBase archive: fill in SHA256= in cmake/packages.cmake
#    (cmake -E sha256sum qtbase-everywhere-src-6.8.1.tar.xz)

# 2. configure: builds QtBase once into ~/.cache/cmake-dep/bin/ (15-60 min)
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build

# 3. a second checkout / worktree / build dir: no rebuild, configure takes seconds
cmake -B build2 -G Ninja -DCMAKE_BUILD_TYPE=Release
```

QtBase needs its usual build prerequisites (a C++17 compiler, and on Linux the X11/xcb or Wayland
development packages for the `Gui` module). See the Qt documentation for your platform.

## Share the build with your team

```bash
# CI (or whoever is trusted to publish binaries):
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMDEP_BINARY_PUSH=https://cmdep.lan.example.com

# everyone else -- downloads the installed QtBase instead of building it:
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMDEP_BINARY_MIRRORS=https://cmdep.lan.example.com
```

Keys only match between machines with the same platform (compiler version, OS, glibc). Teams on a
shared toolchain or Docker image can set `CMDEP_BINARY_PLATFORM` to a common tag. See
[docs/binary-packages.md](../../docs/binary-packages.md).

> This example could not be built in the environment it was written in (no access to
> download.qt.io). The cmake-dep side is covered by `tests/CmDepBinaryTest.cmake`. If QtBase trips
> over something, `--log-level=VERBOSE` and the build logs under `~/.cache/cmake-dep/.tmp/` are the
> place to look.
