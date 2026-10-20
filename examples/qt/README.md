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

## What was validated

This setup was exercised with QtBase 6.8.1 pinned from git (`cmdep add qtbase 6.8.1
https://github.com/qt/qtbase.git --git v6.8.1`), built Core-only (`-DFEATURE_gui=OFF`, because
that machine had no X11 development packages), on Linux with GCC 13 and 4 cores:

| Step | Result |
|---|---|
| First configure (builds QtBase into the cache) | 4m45s, then a `Q_OBJECT` app builds with AUTOMOC and runs |
| Configure of a second build directory | 0.7 s, cache hit |
| Fresh cache at a different path, binary from the mirror | 1 s with `LAZY` (no Qt source fetched); 7 Qt files had their install prefix rewritten; the app links `libQt6Core` from the new location and runs |

If QtBase trips over something in your setup, `--log-level=VERBOSE` and the build logs under
`~/.cache/cmake-dep/.tmp/bin-qtbase-*/` are the place to look.
