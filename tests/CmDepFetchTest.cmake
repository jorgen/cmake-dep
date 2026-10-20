# Offline tests for the cmake-dep fetch path. Run with:
#   cmake -P tests/CmDepFetchTest.cmake
#
# Uses file:// archives and (if python3 is available) a local HTTP server on
# 127.0.0.1, so no internet access is needed.
cmake_minimum_required(VERSION 3.18)

get_filename_component(_repo "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if (NOT WORK_DIR)
    set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/cmdep-test-work")
endif ()
file(TO_CMAKE_PATH "${WORK_DIR}" WORK_DIR)  # e.g. D:\a\_temp on Windows CI
file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")

set(CACHE_DIR "${WORK_DIR}/cache")
include("${CMAKE_CURRENT_LIST_DIR}/CmDepTestHelpers.cmake")

# --- fixtures --------------------------------------------------------------
make_archive(TGZ1 H1 "dep-1.0" "add_library(dep INTERFACE)\n")
make_archive(TGZ2 H2 "dep-1.0-patched" "add_library(dep INTERFACE)\n# patched\n")
string(SUBSTRING "${H1}" 0 12 S1)
string(SUBSTRING "${H2}" 0 12 S2)

file(WRITE "${WORK_DIR}/packages.cmake"
    "CmDepFetchPackage(dep 1.0 \"${FU}${TGZ1}\" SHA256=${H1})\n")
file(WRITE "${WORK_DIR}/bad-packages.cmake"
    "CmDepFetchPackage(bad 1.0 \"${FU}${TGZ1}\" SHA256=0000000000000000000000000000000000000000000000000000000000000000)\n")
file(WRITE "${WORK_DIR}/file-packages.cmake"
    "CmDepFetchFile(single 1.0 \"${FU}${TGZ1}\" renamed.tgz SHA256=${H1})\n")

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
    "-DPROJ_DEP_URL=${FU}${TGZ2}" -DPROJ_DEP_SHA256=${H2})
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
if (WIN32)
    set(_home_env "LOCALAPPDATA=${_home}")
    set(_default_cache "${_home}/cmake-dep")
else ()
    set(_home_env "HOME=${_home}")
    set(_default_cache "${_home}/.cache/cmake-dep")
endif ()
execute_process(
    COMMAND ${CMAKE_COMMAND} -E env --unset=CMDEP_DIR --unset=XDG_CACHE_HOME
            CMDEP_CONFIG=${WORK_DIR}/no-such-config.cmake ${_home_env}
            ${CMAKE_COMMAND} -DCMDEP_PROJECT=proj -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake
            -P "${_repo}/cmake/CmDepFetchDependencies.cmake"
    RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
check("rc EQUAL 0 AND EXISTS \"${_default_cache}/dep-1.0-${S1}/.cmake-dep-complete\"" "default cache location (~/.cache/cmake-dep, %LOCALAPPDATA% on Windows)")
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

# ===========================================================================
# Mirrors, archive store, write-back, config file
# ===========================================================================
set(BOGUS_URL "${FU}${WORK_DIR}/does-not-exist.tar.gz")
file(WRITE "${WORK_DIR}/bogus-packages.cmake"
    "CmDepFetchPackage(dep 1.0 \"${BOGUS_URL}\" SHA256=${H1})\n")
file(WRITE "${WORK_DIR}/two-packages.cmake"
    "CmDepFetchPackage(dep 1.0 \"${FU}${TGZ1}\" SHA256=${H1})\n"
    "CmDepFetchPackage(dep2 1.0 \"${FU}${TGZ2}\" SHA256=${H2})\n")
set(M_EMPTY "${WORK_DIR}/mirror-empty")
set(M_BAD "${WORK_DIR}/mirror-bad")
set(M_GOOD "${WORK_DIR}/mirror-good")
set(M_PUSH "${WORK_DIR}/mirror-push")
file(MAKE_DIRECTORY "${M_EMPTY}" "${M_BAD}/sha256" "${M_GOOD}/sha256")
file(WRITE "${M_BAD}/sha256/${H1}" "this is not the archive")
configure_file("${TGZ1}" "${M_GOOD}/sha256/${H1}" COPYONLY)
set(STORE1 "${CACHE_DIR}/archives/sha256/${H1}")

# --- 13. archive store ------------------------------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake)
check("rc EQUAL 0 AND EXISTS \"${STORE1}\"" "archive kept in <cache>/archives/sha256/<hex> by default")
file(REMOVE_RECURSE "${D1}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/bogus-packages.cmake "-DCMDEP_MIRRORS=${M_EMPTY}")
string(FIND "${log}" "downloading" _dl)
check("rc EQUAL 0 AND _dl EQUAL -1 AND EXISTS \"${D1}/CMakeLists.txt\"" "extracted tree rebuilt from archive store with no network source")
file(STRINGS "${D1}/.cmake-dep-complete" _src REGEX "^source=")
check("_src STREQUAL \"source=store\"" "stamp records source=store")

file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake -DCMDEP_KEEP_ARCHIVES=OFF)
check("rc EQUAL 0 AND NOT EXISTS \"${STORE1}\"" "CMDEP_KEEP_ARCHIVES=OFF keeps no archive")

file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/file-packages.cmake)
check("rc EQUAL 0 AND EXISTS \"${STORE1}\" AND EXISTS \"${CACHE_DIR}/single-1.0-${S1}/renamed.tgz\"" "CmDepFetchFile also fills the archive store")

# --- 14. mirror order: missing -> corrupt -> good ---------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/bogus-packages.cmake
    "-DCMDEP_MIRRORS=${M_EMPTY},${FU}${M_BAD},${FU}${M_GOOD}")
string(FIND "${log}" "served a corrupt copy" _bad)
string(FIND "${log}" "fetched from mirror ${FU}${M_GOOD}" _good)
check("rc EQUAL 0 AND EXISTS \"${D1}/CMakeLists.txt\"" "falls through missing and corrupt mirrors to a good one")
check("NOT _bad EQUAL -1 AND NOT _good EQUAL -1" "corrupt mirror reported, good mirror named")

# --- 15. mirrors-only miss fails with a clear message ----------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake "-DCMDEP_MIRRORS=${M_EMPTY},${FU}${M_BAD}")
string(FIND "${log}" "'direct' is not in CMDEP_MIRRORS" _hint)
string(FIND "${log}" "${M_EMPTY}: not present" _miss)
check("NOT rc EQUAL 0 AND NOT _hint EQUAL -1 AND NOT _miss EQUAL -1" "mirrors-only miss fails listing every source tried")
file(GLOB _left "${CACHE_DIR}/.tmp/*")
check("NOT _left" "failed fetch leaves no temp dir")

# --- 16. direct as fallback ---------------------------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake "-DCMDEP_MIRRORS=${M_EMPTY},direct")
check("rc EQUAL 0 AND EXISTS \"${D1}/CMakeLists.txt\"" "'direct' after a missing mirror falls back to upstream")

# --- 17. write-back ---------------------------------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}" "${M_PUSH}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake "-DCMDEP_MIRROR_PUSH=${FU}${M_PUSH}")
file(GLOB _parts "${M_PUSH}/sha256/*.part-*")
check("rc EQUAL 0 AND EXISTS \"${M_PUSH}/sha256/${H1}\" AND NOT _parts" "fresh download pushed to CMDEP_MIRROR_PUSH")
file(SHA256 "${M_PUSH}/sha256/${H1}" _ph)
check("_ph STREQUAL H1" "pushed blob is intact")
file(REMOVE_RECURSE "${M_PUSH}" "${D1}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake "-DCMDEP_MIRROR_PUSH=${M_PUSH}")
check("rc EQUAL 0 AND NOT EXISTS \"${M_PUSH}\"" "archive-store hit is not pushed")
file(REMOVE_RECURSE "${CACHE_DIR}")
file(WRITE "${WORK_DIR}/ro-file" "")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake "-DCMDEP_MIRROR_PUSH=${WORK_DIR}/ro-file/sub")
string(FIND "${log}" "could not push" _np)
check("rc EQUAL 0 AND NOT _np EQUAL -1 AND EXISTS \"${D1}/CMakeLists.txt\"" "failed push warns but does not fail the fetch")

# --- 18. user config file and precedence -------------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
file(WRITE "${WORK_DIR}/user-config.cmake"
    "set(CMDEP_MIRRORS \"${FU}${M_GOOD}\")\nset(CMDEP_KEEP_ARCHIVES OFF)\n")
set(RUN_ENV "CMDEP_CONFIG=${WORK_DIR}/user-config.cmake")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/bogus-packages.cmake)
check("rc EQUAL 0 AND EXISTS \"${D1}/CMakeLists.txt\" AND NOT EXISTS \"${STORE1}\"" "config file supplies CMDEP_MIRRORS and CMDEP_KEEP_ARCHIVES")
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/bogus-packages.cmake -DCMDEP_MIRRORS=direct)
check("NOT rc EQUAL 0" "-D variable overrides config file")
set(RUN_ENV "CMDEP_CONFIG=${WORK_DIR}/user-config.cmake" "CMDEP_MIRRORS=${M_EMPTY}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/bogus-packages.cmake)
check("NOT rc EQUAL 0" "environment variable overrides config file")
set(RUN_ENV "")

# --- 19. dead mirror is skipped for the rest of the run -----------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/two-packages.cmake
    "-DCMDEP_MIRRORS=http://127.0.0.1:9,direct" -DCMDEP_MIRROR_TIMEOUT=2)
count_matches(_n "${log}" "unreachable (")
check("rc EQUAL 0 AND _n EQUAL 1" "unreachable mirror tried once, then skipped (reported ${_n}x)")

# --- 20. CmDepMirror.cmake populates a mirror -------------------------------
set(M_OUT "${WORK_DIR}/mirror-out")
file(REMOVE_RECURSE "${CACHE_DIR}" "${M_OUT}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/packages.cmake)  # fills the archive store
run_mirror(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/bogus-packages.cmake
    -DCMDEP_MIRROR_OUT=${M_OUT} "-DCMDEP_MIRRORS=${M_EMPTY}")
check("rc EQUAL 0 AND EXISTS \"${M_OUT}/sha256/${H1}\"" "mirror populated from the local archive store, no network")
run_mirror(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/two-packages.cmake -DCMDEP_MIRROR_OUT=${FU}${M_OUT})
check("rc EQUAL 0 AND EXISTS \"${M_OUT}/sha256/${H2}\"" "missing archive fetched upstream into the mirror")
string(FIND "${log}" "already in" _already)
check("NOT _already EQUAL -1" "archives already in the mirror are skipped")
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/bogus-packages.cmake "-DCMDEP_MIRRORS=${M_OUT}")
check("rc EQUAL 0 AND EXISTS \"${D1}/CMakeLists.txt\"" "a populated mirror serves a mirrors-only fetch")

# --- 22. configure mode: mirrors set in CMakeLists, ';'-separated list --------
file(REMOVE_RECURSE "${CACHE_DIR}")
set(_mproj "${WORK_DIR}/mproj")
file(MAKE_DIRECTORY "${_mproj}")
file(WRITE "${_mproj}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.18)\n"
    "project(mproj LANGUAGES NONE)\n"
    "list(APPEND CMAKE_MODULE_PATH \"${_repo}/cmake\")\n"
    "include(CmDepMain)\n"
    "set(CMDEP_MIRRORS \"${M_EMPTY}\" \"${FU}${M_GOOD}\")\n"
    "set(CMDEP_PACKAGES_FILE \"${WORK_DIR}/bogus-packages.cmake\")\n"
    "CmDepFetch()\n"
    "CmDepAddPackage(dep)\n")
execute_process(COMMAND ${CMAKE_COMMAND} -E env CMDEP_CONFIG=${WORK_DIR}/no-such-config.cmake
        ${CMAKE_COMMAND} -S "${_mproj}" -B "${_mproj}/build" -DCMDEP_DIR=${CACHE_DIR}
    RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
check("rc EQUAL 0 AND EXISTS \"${D1}/CMakeLists.txt\"" "configure mode honours CMDEP_MIRRORS set as a CMake list")

# --- 21. HTTP mirror, auth header, PUT write-back (needs python3) ------------
find_program(PYTHON3 NAMES python3 python)
if (PYTHON3)
    set(HTTP_ROOT "${WORK_DIR}/http-root")
    file(REMOVE_RECURSE "${HTTP_ROOT}")
    file(MAKE_DIRECTORY "${HTTP_ROOT}/upstream")
    configure_file("${TGZ1}" "${HTTP_ROOT}/upstream/dep.tar.gz" COPYONLY)
    configure_file("${TGZ2}" "${HTTP_ROOT}/upstream/dep2.tar.gz" COPYONLY)
    # Server and client run concurrently (one execute_process pipeline).
    execute_process(
        COMMAND ${PYTHON3} "${CMAKE_CURRENT_LIST_DIR}/mirror_server.py"
                "${HTTP_ROOT}" "${WORK_DIR}/http-port" "Bearer s3cret"
        COMMAND ${CMAKE_COMMAND} -DWORK_DIR=${WORK_DIR} -DH1=${H1} -DH2=${H2}
                -P "${CMAKE_CURRENT_LIST_DIR}/CmDepMirrorHttpTest.cmake"
        RESULT_VARIABLE _http_rc)
    if (EXISTS "${WORK_DIR}/http-failures")
        file(READ "${WORK_DIR}/http-failures" _hf)
    else ()
        set(_hf 1)
    endif ()
    check("_hf EQUAL 0" "HTTP mirror suite")
else ()
    message(STATUS "SKIP: HTTP mirror tests (python3 not found)")
endif ()

# ===========================================================================
# Binary packages (separate script; needs a C compiler)
# ===========================================================================
execute_process(
    COMMAND ${CMAKE_COMMAND} -DWORK_DIR=${WORK_DIR}/binary -DRESULT_FILE=${WORK_DIR}/binary-failures
            -P "${CMAKE_CURRENT_LIST_DIR}/CmDepBinaryTest.cmake")
if (EXISTS "${WORK_DIR}/binary-failures")
    file(READ "${WORK_DIR}/binary-failures" _bf)
else ()
    set(_bf 1)
endif ()
check("_bf EQUAL 0" "binary package suite")

# ===========================================================================
# Sub-suites run as separate scripts
# ===========================================================================
foreach (_suite Cache Cli)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -DWORK_DIR=${WORK_DIR}/suite-${_suite}
                -DRESULT_FILE=${WORK_DIR}/suite-${_suite}-failures
                -P "${CMAKE_CURRENT_LIST_DIR}/CmDep${_suite}Test.cmake")
    if (EXISTS "${WORK_DIR}/suite-${_suite}-failures")
        file(READ "${WORK_DIR}/suite-${_suite}-failures" _sf)
    else ()
        set(_sf 1)
    endif ()
    check("_sf EQUAL 0" "${_suite} suite")
endforeach ()

if (_failures GREATER 0)
    message(FATAL_ERROR "${_failures} test(s) failed")
endif ()
message(STATUS "All tests passed")
