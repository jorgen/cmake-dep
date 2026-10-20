# Push an already-built binary package from the local cache to a binary mirror.
#
#   cmake -DCMDEP_BINARY_ENTRY=~/.cache/cmake-dep/bin/qtbase-v6.8.1-1a2b3c4d5e6f \
#         -DCMDEP_BINARY_PUSH=https://cmdep.lan.example.com \
#         -P <cmake-dep>/cmake/CmDepBinaryPush.cmake
#
# Normally binaries reach a mirror automatically: a configure with
# CMDEP_BINARY_PUSH set uploads whatever it had to build. This script covers
# the case where the build already happened without it (e.g. a developer built
# Qt locally and wants to share it). Whoever can push binaries is trusted by
# everyone who downloads them -- see docs/binary-packages.md, "Trust".
#
# CMDEP_BINARY_PUSH may be a directory, a file:// URL, or an http(s):// URL that
# accepts PUT. Credentials: ~/.netrc or CMDEP_MIRROR_HTTPHEADER.

# Policies for cmake-dep's own code, so it behaves the same in a configure and
# in a bare `cmake -P` (include() keeps this from leaking into the includer).
cmake_policy(VERSION 3.18)


include("${CMAKE_CURRENT_LIST_DIR}/CmDepBinary.cmake")

if (NOT CMDEP_BINARY_ENTRY OR NOT CMDEP_BINARY_PUSH)
    message(FATAL_ERROR "usage: cmake -DCMDEP_BINARY_ENTRY=<cache>/bin/<entry> "
                        "-DCMDEP_BINARY_PUSH=<dir|url> -P CmDepBinaryPush.cmake")
endif ()
get_filename_component(_entry "${CMDEP_BINARY_ENTRY}" ABSOLUTE)
if (NOT EXISTS "${_entry}/.cmake-dep-complete" OR NOT EXISTS "${_entry}/.cmake-dep-binary.txt")
    message(FATAL_ERROR "cmake-dep: ${_entry} is not a complete binary package entry")
endif ()
file(STRINGS "${_entry}/.cmake-dep-binary.txt" _key REGEX "^key=")
file(STRINGS "${_entry}/.cmake-dep-binary.txt" _name REGEX "^name=")
string(REGEX REPLACE "^key=" "" _key "${_key}")
string(REGEX REPLACE "^name=" "" _name "${_name}")

# Pack a copy without the local completion stamp.
get_filename_component(_root "${_entry}/../.." ABSOLUTE)
get_filename_component(_entry_name "${_entry}" NAME)
set(_work "${_root}/.tmp/push-${_entry_name}")
file(REMOVE_RECURSE "${_work}")
file(MAKE_DIRECTORY "${_work}")
file(COPY "${_entry}/" DESTINATION "${_work}/prefix")
file(REMOVE "${_work}/prefix/.cmake-dep-complete")
_CmDepBinaryPush("${_name}" "${_key}" "${_work}/prefix" "${_work}" "${CMDEP_BINARY_PUSH}")
file(REMOVE_RECURSE "${_work}")
