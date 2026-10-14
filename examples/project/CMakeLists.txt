# Example project: fetches libuv and doctest through cmake-dep.
#
#   cmake -B build && cmake --build build && ctest --test-dir build
#
# Try it with a mirror:
#   cmake -B build -DCMDEP_MIRRORS=/path/to/mirror,direct
cmake_minimum_required(VERSION 3.18)
project(cmdep_example LANGUAGES C CXX)

# --- cmake-dep -------------------------------------------------------------
include(FetchContent)
FetchContent_Declare(cmake-dep
    GIT_REPOSITORY https://github.com/jorgen/cmake-dep.git
    GIT_TAG main
)
# Inside the cmake-dep repository itself, use this checkout instead:
if (EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/CmDepMain.cmake")
    set(FETCHCONTENT_SOURCE_DIR_CMAKE-DEP "${CMAKE_CURRENT_SOURCE_DIR}/../.." CACHE PATH "")
endif ()
FetchContent_MakeAvailable(cmake-dep)
list(APPEND CMAKE_MODULE_PATH "${cmake-dep_SOURCE_DIR}/cmake")
include(CmDepMain)

# --- dependencies ----------------------------------------------------------
# Downloads into ~/.cache/cmake-dep on first configure (or from CMDEP_MIRRORS).
# Each also gets CMDEP_EXAMPLE_USE_SYSTEM_<DEP> / _VERSION / _URL / _SHA256 knobs.
set(CMDEP_PACKAGES_FILE "${CMAKE_CURRENT_SOURCE_DIR}/cmake/packages.cmake")
CmDepFetch()

# system copy if -DCMDEP_EXAMPLE_USE_SYSTEM_LIBUV=ON, otherwise build the fetched source
CmDepAddPackage(libuv CONFIG
    OPTIONS LIBUV_BUILD_TESTS=OFF LIBUV_BUILD_BENCH=OFF LIBUV_BUILD_SHARED=OFF)
if (TARGET uv_a)
    set(LIBUV_TARGET uv_a)          # bundled build
else ()
    set(LIBUV_TARGET libuv::uv_a)   # system package
endif ()

CmDepAddPackage(doctest CONFIG OPTIONS DOCTEST_WITH_TESTS=OFF)

# --- targets ---------------------------------------------------------------
add_executable(example src/main.cpp)
target_link_libraries(example PRIVATE ${LIBUV_TARGET})

enable_testing()
add_executable(example_tests tests/test_main.cpp)
target_link_libraries(example_tests PRIVATE doctest::doctest ${LIBUV_TARGET})
add_test(NAME example_tests COMMAND example_tests)
