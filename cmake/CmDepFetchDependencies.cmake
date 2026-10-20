# Standalone dependency fetcher.
#
# Can be used directly as a script:
#   cmake -DCMDEP_PACKAGES_FILE=CMake/3rdPartyPackages.cmake -P <cmake-dep>/cmake/CmDepFetchDependencies.cmake
#
# Optional variables (pass with -D):
#   CMDEP_PACKAGES_FILE  - path to the packages file (required in script mode)
#   CMDEP_PROJECT_ROOT   - project root directory (defaults to cwd); a relative
#                          CMDEP_DIR is resolved against it
#   CMDEP_MIRRORS        - ordered sources, e.g. "https://mirror.lan,direct"
#                          (see docs/caching-and-mirrors.md)
#   CMDEP_DIR            - override the fetch directory (default: the shared
#                          per-user cache, see CmDepCacheDir)
#   CMDEP_PROJECT        - knob prefix (enables -D<PREFIX>_<DEP>_URL/_SHA256/_VERSION
#                          overrides and <PREFIX>_USE_SYSTEM_<DEP> skips; without it
#                          the packages file's positional defaults are used)
#
# Or include() it and call the function directly:
#   include(CmDepFetchDependencies)
#   CmDepFetchSetup(project_root packages_file)
#
# This uses the exact same fetch path (CmDepFetch.cmake) as a configure, so a
# pre-fetch here is a cache hit there.

# Policies for cmake-dep's own code, so it behaves the same in a configure and
# in a bare `cmake -P` (include() keeps this from leaking into the includer).
cmake_policy(VERSION 3.18)


include("${CMAKE_CURRENT_LIST_DIR}/CmDepFetch.cmake")

function(CmDepFetchSetup project_root packages_file)
    set(CMDEP_PROJECT_ROOT "${project_root}")
    CmDepCacheDir(_dir)
    message(STATUS "cmake-dep: fetch directory: ${_dir}")
    _CmDepFetchRoot("${packages_file}")  # includes the locked transitive packages
    message(STATUS "cmake-dep: all dependencies fetched to: ${_dir}")
endfunction()

# Auto-invoke when run as: cmake -DCMDEP_PACKAGES_FILE=... -P CmDepFetchDependencies.cmake
if(DEFINED CMDEP_PACKAGES_FILE AND CMAKE_SCRIPT_MODE_FILE)
    if(NOT CMDEP_PROJECT_ROOT)
        set(CMDEP_PROJECT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}")
    endif()
    get_filename_component(CMDEP_PROJECT_ROOT "${CMDEP_PROJECT_ROOT}" ABSOLUTE)
    get_filename_component(CMDEP_PACKAGES_FILE "${CMDEP_PACKAGES_FILE}" ABSOLUTE)

    if(NOT EXISTS "${CMDEP_PACKAGES_FILE}")
        message(FATAL_ERROR "Packages file not found: ${CMDEP_PACKAGES_FILE}")
    endif()

    CmDepFetchSetup("${CMDEP_PROJECT_ROOT}" "${CMDEP_PACKAGES_FILE}")
endif()
