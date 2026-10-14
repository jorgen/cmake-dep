# Offline tests for the cmake-dep fetch path. Run with:
#   cmake -P tests/CmDepFetchTest.cmake
#
# Uses file:// archives in a scratch directory, so no network is needed.
cmake_minimum_required(VERSION 3.18)

get_filename_component(_repo "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if (NOT WORK_DIR)
    set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/cmdep-test-work")
endif ()
file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")

set(_failures 0)
macro(check cond msg)
    cmake_language(EVAL CODE "if (${cond})\n set(_chk TRUE)\nelse ()\n set(_chk FALSE)\nendif ()")
    if (_chk)
        message(STATUS "PASS: ${msg}")
    else ()
        message(STATUS "FAIL: ${msg}")
        math(EXPR _failures "${_failures} + 1")
    endif ()
endmacro()

# --- fixtures --------------------------------------------------------------
function(make_archive out_path out_hash top content)
    set(_src "${WORK_DIR}/src/${top}")
    file(MAKE_DIRECTORY "${_src}/sub")
    file(WRITE "${_src}/CMakeLists.txt" "${content}")
    file(WRITE "${_src}/.hidden" "x")
    file(WRITE "${_src}/sub/a.txt" "a")
    set(_tgz "${WORK_DIR}/${top}.tar.gz")
    execute_process(COMMAND ${CMAKE_COMMAND} -E tar czf "${_tgz}" "${top}"
        WORKING_DIRECTORY "${WORK_DIR}/src" RESULT_VARIABLE _r)
    if (NOT _r EQUAL 0)
        message(FATAL_ERROR "tar failed")
    endif ()
    file(SHA256 "${_tgz}" _h)
    set(${out_path} "${_tgz}" PARENT_SCOPE)
    set(${out_hash} "${_h}" PARENT_SCOPE)
endfunction()

make_archive(TGZ1 H1 "dep-1.0" "add_library(dep INTERFACE)\n")
make_archive(TGZ2 H2 "dep-1.0-patched" "add_library(dep INTERFACE)\n# patched\n")
string(SUBSTRING "${H1}" 0 12 S1)
string(SUBSTRING "${H2}" 0 12 S2)
set(CACHE_DIR "${WORK_DIR}/cache")

file(WRITE "${WORK_DIR}/packages.cmake"
    "CmDepFetchPackage(dep 1.0 \"file://${TGZ1}\" SHA256=${H1})\n")
file(WRITE "${WORK_DIR}/bad-packages.cmake"
    "CmDepFetchPackage(bad 1.0 \"file://${TGZ1}\" SHA256=0000000000000000000000000000000000000000000000000000000000000000)\n")
file(WRITE "${WORK_DIR}/file-packages.cmake"
    "CmDepFetchFile(single 1.0 \"file://${TGZ1}\" renamed.tgz SHA256=${H1})\n")

function(run_fetch out_rc out_log)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -DCMDEP_DIR=${CACHE_DIR} -DCMDEP_PROJECT=proj ${ARGN}
                -P "${_repo}/cmake/CmDepFetchDependencies.cmake"
        RESULT_VARIABLE _rc OUTPUT_VARIABLE _out ERROR_VARIABLE _err)
    set(${out_rc} "${_rc}" PARENT_SCOPE)
    set(${out_log} "${_out}${_err}" PARENT_SCOPE)
endfunction()

set(D1 "${CACHE_DIR}/dep-1.0-${S1}")

# --- 1. fresh fetch --------------------------------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake)
check("rc EQUAL 0" "fresh fetch succeeds")
check("EXISTS \"${D1}/.cmake-dep-complete\"" "stamp written into <name>-<version>-<hash12>")
check("EXISTS \"${D1}/CMakeLists.txt\"" "single top-level directory stripped")
check("EXISTS \"${D1}/.hidden\"" "hidden files preserved")
file(GLOB _tmp_left "${CACHE_DIR}/.tmp/*")
check("NOT _tmp_left" "temp directory cleaned up")

# --- 2. cache hit ----------------------------------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake)
string(FIND "${log}" "downloading" _dl)
check("rc EQUAL 0 AND _dl EQUAL -1" "second run is a cache hit (no download)")

# --- 3. partial directory (no stamp) is removed and re-fetched -------------
file(REMOVE "${D1}/.cmake-dep-complete" "${D1}/CMakeLists.txt")
file(WRITE "${D1}/garbage" "partial")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake)
string(FIND "${log}" "incomplete" _inc)
check("rc EQUAL 0 AND NOT _inc EQUAL -1" "unstamped dir detected as incomplete")
check("EXISTS \"${D1}/.cmake-dep-complete\" AND EXISTS \"${D1}/CMakeLists.txt\"" "re-fetch restores full tree + stamp")
check("NOT EXISTS \"${D1}/garbage\"" "partial content removed")

# --- 4. leftover temp dir from a crashed fetch is cleared ------------------
file(REMOVE_RECURSE "${D1}")
file(MAKE_DIRECTORY "${CACHE_DIR}/.tmp/dep-1.0-${S1}/junk")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake)
check("rc EQUAL 0 AND EXISTS \"${D1}/.cmake-dep-complete\"" "fetch succeeds over a stale temp dir")
check("NOT EXISTS \"${CACHE_DIR}/.tmp/dep-1.0-${S1}\"" "stale temp dir removed")

# --- 5. URL/hash override with same version gets its own directory ---------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake
    "-DPROJ_DEP_URL=file://${TGZ2}" -DPROJ_DEP_SHA256=${H2})
check("rc EQUAL 0 AND EXISTS \"${CACHE_DIR}/dep-1.0-${S2}/.cmake-dep-complete\"" "override fetched into hash-keyed dir")
check("EXISTS \"${D1}/.cmake-dep-complete\"" "original entry untouched by override")

# --- 6. hash mismatch fails cleanly ----------------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/bad-packages.cmake)
file(GLOB _bad "${CACHE_DIR}/bad-*" "${CACHE_DIR}/.tmp/bad-*")
check("NOT rc EQUAL 0" "hash mismatch is fatal")
check("NOT _bad" "hash mismatch leaves no directory behind")

# --- 7. USE_SYSTEM skips the fetch -----------------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake -DPROJ_USE_SYSTEM_DEP=ON)
check("rc EQUAL 0 AND NOT EXISTS \"${D1}\"" "USE_SYSTEM skips download")

# --- 8. single-file fetch --------------------------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/file-packages.cmake)
check("rc EQUAL 0 AND EXISTS \"${CACHE_DIR}/single-1.0-${S1}/renamed.tgz\" AND EXISTS \"${CACHE_DIR}/single-1.0-${S1}/.cmake-dep-complete\"" "CmDepFetchFile uses the same stamped path")

# --- 9. a held lock makes a second fetcher wait ----------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
file(MAKE_DIRECTORY "${CACHE_DIR}/.locks")
file(WRITE "${WORK_DIR}/hold-lock.cmake"
    "file(LOCK \"${CACHE_DIR}/.locks/dep-1.0-${S1}.lock\" GUARD PROCESS)\n"
    "execute_process(COMMAND \${CMAKE_COMMAND} -E sleep 3)\n")
file(WRITE "${WORK_DIR}/delayed-fetch.cmake"
    "execute_process(COMMAND \${CMAKE_COMMAND} -E sleep 1)\n"
    "execute_process(COMMAND \${CMAKE_COMMAND} -DCMDEP_DIR=${CACHE_DIR} -DCMDEP_PROJECT=proj -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake -P ${_repo}/cmake/CmDepFetchDependencies.cmake RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)\n"
    "file(WRITE \"${WORK_DIR}/delayed.log\" \"rc=\${rc}\\n\${out}\${err}\")\n")
# Commands in one execute_process run concurrently.
execute_process(
    COMMAND ${CMAKE_COMMAND} -P "${WORK_DIR}/hold-lock.cmake"
    COMMAND ${CMAKE_COMMAND} -P "${WORK_DIR}/delayed-fetch.cmake")
file(READ "${WORK_DIR}/delayed.log" _dlog)
string(FIND "${_dlog}" "waiting for another process" _wait)
string(FIND "${_dlog}" "rc=0" _rc0)
check("NOT _wait EQUAL -1" "fetcher waits on a held lock")
check("_rc0 EQUAL 0 AND EXISTS \"${D1}/.cmake-dep-complete\"" "fetcher completes after lock is released")

# --- 10. racing fetchers all succeed with one consistent tree ---------------
file(REMOVE_RECURSE "${CACHE_DIR}")
foreach (i RANGE 1 4)
    file(WRITE "${WORK_DIR}/race${i}.cmake"
        "execute_process(COMMAND \${CMAKE_COMMAND} -DCMDEP_DIR=${CACHE_DIR} -DCMDEP_PROJECT=proj -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake -P ${_repo}/cmake/CmDepFetchDependencies.cmake RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)\n"
        "file(WRITE \"${WORK_DIR}/race${i}.log\" \"rc=\${rc}\\n\${out}\${err}\")\n")
endforeach ()
execute_process(
    COMMAND ${CMAKE_COMMAND} -P "${WORK_DIR}/race1.cmake"
    COMMAND ${CMAKE_COMMAND} -P "${WORK_DIR}/race2.cmake"
    COMMAND ${CMAKE_COMMAND} -P "${WORK_DIR}/race3.cmake"
    COMMAND ${CMAKE_COMMAND} -P "${WORK_DIR}/race4.cmake")
set(_all_ok TRUE)
set(_downloads 0)
foreach (i RANGE 1 4)
    file(READ "${WORK_DIR}/race${i}.log" _rl)
    string(FIND "${_rl}" "rc=0" _p)
    if (NOT _p EQUAL 0)
        set(_all_ok FALSE)
    endif ()
    string(FIND "${_rl}" "downloading" _p)
    if (NOT _p EQUAL -1)
        math(EXPR _downloads "${_downloads} + 1")
    endif ()
endforeach ()
check("_all_ok" "all racing fetchers succeed")
check("_downloads EQUAL 1" "exactly one racing fetcher downloads (got ${_downloads})")
check("EXISTS \"${D1}/.cmake-dep-complete\" AND EXISTS \"${D1}/sub/a.txt\"" "raced tree is complete")

# --- 11. configure mode uses the same path ----------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
set(_proj "${WORK_DIR}/proj")
file(MAKE_DIRECTORY "${_proj}")
file(WRITE "${_proj}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.18)\n"
    "project(proj LANGUAGES NONE)\n"
    "list(APPEND CMAKE_MODULE_PATH \"${_repo}/cmake\")\n"
    "include(CmDepMain)\n"
    "set(CMDEP_PACKAGES_FILE \"${WORK_DIR}/packages.cmake\")\n"
    "CmDepFetch()\n"
    "if (NOT dep_SOURCE_DIR STREQUAL \"${D1}\")\n"
    "  message(FATAL_ERROR \"dep_SOURCE_DIR=\${dep_SOURCE_DIR}\")\n"
    "endif ()\n"
    "CmDepAddPackage(dep)\n"
    "if (NOT TARGET dep)\n"
    "  message(FATAL_ERROR \"target dep missing\")\n"
    "endif ()\n")
execute_process(COMMAND ${CMAKE_COMMAND} -S "${_proj}" -B "${_proj}/build" -DCMDEP_DIR=${CACHE_DIR}
    RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
if (NOT rc EQUAL 0)
    message(STATUS "${out}${err}")
endif ()
check("rc EQUAL 0 AND EXISTS \"${D1}/.cmake-dep-complete\"" "configure-mode CmDepFetch + CmDepAddPackage")

# --- 12. default directory is ~/.cache/cmake-dep (via XDG/HOME) -------------
set(_home "${WORK_DIR}/home")
execute_process(
    COMMAND ${CMAKE_COMMAND} -E env --unset=CMDEP_DIR --unset=XDG_CACHE_HOME HOME=${_home}
            ${CMAKE_COMMAND} -DCMDEP_PROJECT=proj -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake
            -P "${_repo}/cmake/CmDepFetchDependencies.cmake"
    RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
check("rc EQUAL 0 AND EXISTS \"${_home}/.cache/cmake-dep/dep-1.0-${S1}/.cmake-dep-complete\"" "default cache is ~/.cache/cmake-dep")
execute_process(
    COMMAND ${CMAKE_COMMAND} -E env --unset=CMDEP_DIR XDG_CACHE_HOME=${WORK_DIR}/xdg
            ${CMAKE_COMMAND} -DCMDEP_PROJECT=proj -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake
            -P "${_repo}/cmake/CmDepFetchDependencies.cmake"
    RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
check("rc EQUAL 0 AND EXISTS \"${WORK_DIR}/xdg/cmake-dep/dep-1.0-${S1}/.cmake-dep-complete\"" "XDG_CACHE_HOME respected")
execute_process(
    COMMAND ${CMAKE_COMMAND} -E env CMDEP_DIR=3rdparty
            ${CMAKE_COMMAND} -DCMDEP_PROJECT=proj -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake
            -DCMDEP_PROJECT_ROOT=${_proj} -P "${_repo}/cmake/CmDepFetchDependencies.cmake"
    RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
check("rc EQUAL 0 AND EXISTS \"${_proj}/3rdparty/dep-1.0-${S1}/.cmake-dep-complete\"" "relative CMDEP_DIR (env) resolves against project root")

if (_failures GREATER 0)
    message(FATAL_ERROR "${_failures} test(s) failed")
endif ()
message(STATUS "All tests passed")
