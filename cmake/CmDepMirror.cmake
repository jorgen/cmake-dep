# Populate a cmake-dep mirror with every archive a packages file references.
#
#   cmake -DCMDEP_PACKAGES_FILE=CMake/3rdPartyPackages.cmake \
#         -DCMDEP_MIRROR_OUT=/srv/cmake-dep-mirror \
#         -P <cmake-dep>/cmake/CmDepMirror.cmake
#
# CMDEP_MIRROR_OUT is a directory, a file:// URL, or an http(s):// URL that
# accepts HTTP PUT (WebDAV, Artifactory/Nexus generic repos, ...). Archives are
# written content-addressed as <out>/<algo>/<hex>, the layout CMDEP_MIRRORS
# reads.
#
# Each archive is taken from the first source that has it: the local archive
# store (~/.cache/cmake-dep/archives), then CMDEP_MIRRORS (default: the
# upstream URL). So on a machine that has already configured the project, this
# needs no network at all.
#
# Optional (-D):
#   CMDEP_PROJECT       knob prefix, so -D<PREFIX>_<DEP>_URL/_SHA256/_VERSION
#                       overrides apply here too
#   CMDEP_PROJECT_ROOT  project root (relative CMDEP_DIR resolves against it)
#   CMDEP_DIR, CMDEP_MIRRORS, CMDEP_MIRROR_HTTPHEADER, ...  as for a configure
#
# Run it against several packages files (or projects) to build one shared mirror.

include("${CMAKE_CURRENT_LIST_DIR}/CmDepFetch.cmake")

function(CmDepMirrorPackages packages_file)
    if (NOT CMDEP_MIRROR_OUT)
        message(FATAL_ERROR "cmake-dep: CMDEP_MIRROR_OUT must be set")
    endif ()
    message(STATUS "cmake-dep: populating mirror ${CMDEP_MIRROR_OUT} from ${packages_file}")
    include("${packages_file}")
    message(STATUS "cmake-dep: mirror ${CMDEP_MIRROR_OUT} is up to date")
endfunction()

if (CMAKE_SCRIPT_MODE_FILE STREQUAL CMAKE_CURRENT_LIST_FILE)
    if (NOT CMDEP_PACKAGES_FILE)
        message(FATAL_ERROR "usage: cmake -DCMDEP_PACKAGES_FILE=<file> -DCMDEP_MIRROR_OUT=<dir|url> "
                            "-P CmDepMirror.cmake")
    endif ()
    if (NOT CMDEP_PROJECT_ROOT)
        set(CMDEP_PROJECT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}")
    endif ()
    get_filename_component(CMDEP_PROJECT_ROOT "${CMDEP_PROJECT_ROOT}" ABSOLUTE)
    get_filename_component(CMDEP_PACKAGES_FILE "${CMDEP_PACKAGES_FILE}" ABSOLUTE)
    if (NOT EXISTS "${CMDEP_PACKAGES_FILE}")
        message(FATAL_ERROR "Packages file not found: ${CMDEP_PACKAGES_FILE}")
    endif ()
    # A relative local output path is relative to where the command was run.
    _CmDepLocalPath(_cmdep_out_local "${CMDEP_MIRROR_OUT}")
    if (_cmdep_out_local AND NOT IS_ABSOLUTE "${_cmdep_out_local}")
        get_filename_component(CMDEP_MIRROR_OUT "${_cmdep_out_local}" ABSOLUTE)
    endif ()
    CmDepMirrorPackages("${CMDEP_PACKAGES_FILE}")
endif ()
