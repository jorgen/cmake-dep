# Example project

A small project that depends on [libuv](https://libuv.org) and [doctest](https://github.com/doctest/doctest)
through cmake-dep.

```bash
cmake -B build
cmake --build build
ctest --test-dir build
```

On the first configure, both archives are downloaded into `~/.cache/cmake-dep`. Configure again, or
in a second checkout or worktree, and you get cache hits with no network access.

Things to try:

```bash
# per-project vendor directory instead of the shared cache
cmake -B build -DCMDEP_DIR=3rdparty

# build a local mirror from what you just downloaded, then use only that mirror
rsync -a ~/.cache/cmake-dep/archives/ /tmp/my-mirror/
cmake -B build2 -DCMDEP_DIR=/tmp/empty-cache -DCMDEP_MIRRORS=/tmp/my-mirror

# use the system libuv instead of building it
cmake -B build -DCMDEP_EXAMPLE_USE_SYSTEM_LIBUV=ON
```
