# Tests for the `cmdep` command line (bin/cmdep, bin/cmdep.cmd on Windows).
# Run with: cmake -P tests/CmDepCliTest.cmake (also run by CmDepFetchTest.cmake).
cmake_minimum_required(VERSION 3.18)

get_filename_component(_repo "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if (NOT WORK_DIR)
    set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/cmdep-cli-test-work")
endif ()
file(TO_CMAKE_PATH "${WORK_DIR}" WORK_DIR)  # e.g. D:\a\_temp on Windows CI
file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")
set(CACHE_DIR "${WORK_DIR}/cache")
include("${CMAKE_CURRENT_LIST_DIR}/CmDepTestHelpers.cmake")
if (RESULT_FILE)
    file(WRITE "${RESULT_FILE}" "1")
endif ()

if (WIN32)
    set(CMDEP "${_repo}/bin/cmdep.cmd")
else ()
    set(CMDEP "${_repo}/bin/cmdep")
endif ()

make_archive(TGZ H "lib-2.0" "add_library(lib INTERFACE)\n")
string(SUBSTRING "${H}" 0 12 S)
set(PROJ "${WORK_DIR}/proj")
file(MAKE_DIRECTORY "${PROJ}")

# cmdep(<rc> <log> args...) -- runs in ${PROJ}, isolated environment
function(cmdep out_rc out_log)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E env --unset=CMDEP_MIRRORS --unset=CMDEP_PACKAGES_FILE
                CMDEP_CONFIG=${WORK_DIR}/no-such-config.cmake CMDEP_DIR=${CACHE_DIR}
                CMAKE=${CMAKE_COMMAND} "${CMDEP}" ${ARGN}
        WORKING_DIRECTORY "${PROJ}"
        RESULT_VARIABLE _rc OUTPUT_VARIABLE _out ERROR_VARIABLE _err)
    set(${out_rc} "${_rc}" PARENT_SCOPE)
    set(${out_log} "${_out}${_err}" PARENT_SCOPE)
endfunction()

# --- C1. help / unknown command -------------------------------------------------
cmdep(rc log help)
string(FIND "${log}" "usage: cmdep" _u)
check("rc EQUAL 0 AND NOT _u EQUAL -1" "cmdep help prints usage")
cmdep(rc log frobnicate)
check("NOT rc EQUAL 0" "unknown command fails")
cmdep(rc log cache-dir)
string(STRIP "${log}" _cd)
check("_cd STREQUAL CACHE_DIR" "cmdep cache-dir prints the cache directory")

# --- C2. hash -----------------------------------------------------------------------
cmdep(rc log hash "${TGZ}")
string(FIND "${log}" "SHA256=${H}" _h)
check("rc EQUAL 0 AND NOT _h EQUAL -1" "cmdep hash prints SHA256=<hex> for a file")
cmdep(rc log hash "${FU}${TGZ}" --algo sha512)
file(SHA512 "${TGZ}" _h512)
string(FIND "${log}" "SHA512=${_h512}" _h)
check("rc EQUAL 0 AND NOT _h EQUAL -1" "cmdep hash --algo sha512 on a URL")
check("EXISTS \"${CACHE_DIR}/archives/sha256/${H}\"" "hashed archive kept in the archive store")

# --- C3. add + fetch with the default packages file -------------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
cmdep(rc log add lib 2.0 "${FU}${TGZ}")
check("rc EQUAL 0 AND EXISTS \"${PROJ}/cmdep-packages.cmake\"" "cmdep add creates cmdep-packages.cmake")
file(READ "${PROJ}/cmdep-packages.cmake" _pk)
string(FIND "${_pk}" "CmDepFetchPackage(lib 2.0" _decl)
string(FIND "${_pk}" "SHA256=${H}" _hash)
check("NOT _decl EQUAL -1 AND NOT _hash EQUAL -1" "added declaration has name, version and hash")
cmdep(rc log add lib 2.0 "${FU}${TGZ}")
check("NOT rc EQUAL 0" "adding the same name twice fails")
cmdep(rc log fetch)
string(FIND "${log}" "downloading" _dl)
check("rc EQUAL 0 AND _dl EQUAL -1 AND EXISTS \"${CACHE_DIR}/lib-2.0-${S}/.cmake-dep-complete\"" "cmdep fetch uses the default packages file; the archive from add is reused")

# --- C4. explicit --packages, -D settings, mirror ---------------------------------------
file(RENAME "${PROJ}/cmdep-packages.cmake" "${WORK_DIR}/elsewhere.cmake")
cmdep(rc log fetch)
check("NOT rc EQUAL 0" "fetch without any packages file fails")
cmdep(rc log mirror "${WORK_DIR}/mirror" --packages=${WORK_DIR}/elsewhere.cmake)
check("rc EQUAL 0 AND EXISTS \"${WORK_DIR}/mirror/sha256/${H}\"" "cmdep mirror <dir> --packages=<file>")
file(REMOVE_RECURSE "${CACHE_DIR}")
cmdep(rc log --packages "${WORK_DIR}/elsewhere.cmake" -DCMDEP_MIRRORS=${WORK_DIR}/mirror fetch)
string(FIND "${log}" "fetched from mirror" _fm)
check("rc EQUAL 0 AND NOT _fm EQUAL -1" "-D settings are passed through (CMDEP_MIRRORS)")

# --- C5. status / gc / verify ---------------------------------------------------------------
cmdep(rc log status)
string(FIND "${log}" "lib-2.0-${S}" _st)
check("rc EQUAL 0 AND NOT _st EQUAL -1" "cmdep status lists the entry")
cmdep(rc log gc --older-than 0s --dry-run)
string(FIND "${log}" "would remove" _w)
check("rc EQUAL 0 AND NOT _w EQUAL -1 AND EXISTS \"${CACHE_DIR}/lib-2.0-${S}\"" "cmdep gc --dry-run")
cmdep(rc log verify)
string(FIND "${log}" "0 problem(s)" _v)
check("rc EQUAL 0 AND NOT _v EQUAL -1" "cmdep verify on a healthy cache")

if (RESULT_FILE)
    file(WRITE "${RESULT_FILE}" "${_failures}")
endif ()
if (_failures GREATER 0)
    message(FATAL_ERROR "${_failures} CLI test(s) failed")
endif ()
message(STATUS "All CLI tests passed")
