# Tests for cache maintenance (CmDepCache.cmake: status, gc, verify) and
# last-used tracking. Run with: cmake -P tests/CmDepCacheTest.cmake
# (also run by tests/CmDepFetchTest.cmake). Needs python3 for back-dating
# timestamps; those checks are skipped without it.
cmake_minimum_required(VERSION 3.18)

get_filename_component(_repo "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if (NOT WORK_DIR)
    set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/cmdep-cache-test-work")
endif ()
file(TO_CMAKE_PATH "${WORK_DIR}" WORK_DIR)  # e.g. D:\a\_temp on Windows CI
file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")
set(CACHE_DIR "${WORK_DIR}/cache")
include("${CMAKE_CURRENT_LIST_DIR}/CmDepTestHelpers.cmake")
if (RESULT_FILE)
    file(WRITE "${RESULT_FILE}" "1")
endif ()
find_program(PYTHON3 NAMES python3 python)

make_archive(TGZA HA "a-1.0" "# a\n")
make_archive(TGZB HB "b-1.0" "# b\n")
string(SUBSTRING "${HA}" 0 12 SA)
string(SUBSTRING "${HB}" 0 12 SB)
file(WRITE "${WORK_DIR}/a.cmake" "CmDepFetchPackage(a 1.0 \"${FU}${TGZA}\" SHA256=${HA})\n")
file(WRITE "${WORK_DIR}/b.cmake" "CmDepFetchPackage(b 1.0 \"${FU}${TGZB}\" SHA256=${HB})\n")
set(DA "${CACHE_DIR}/a-1.0-${SA}")
set(DB "${CACHE_DIR}/b-1.0-${SB}")

function(run_cache out_rc out_log action)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E env CMDEP_CONFIG=${WORK_DIR}/no-such-config.cmake
                ${CMAKE_COMMAND} -DCMDEP_DIR=${CACHE_DIR} -DCMDEP_CACHE_ACTION=${action} ${ARGN}
                -P "${_repo}/cmake/CmDepCache.cmake"
        RESULT_VARIABLE _rc OUTPUT_VARIABLE _out ERROR_VARIABLE _err)
    set(${out_rc} "${_rc}" PARENT_SCOPE)
    set(${out_log} "${_out}${_err}" PARENT_SCOPE)
endfunction()

# set_mtime(<path> <seconds-ago>)
function(set_mtime path ago)
    execute_process(COMMAND ${PYTHON3} -c
        "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))" "${path}" "${ago}")
endfunction()

run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/a.cmake)
execute_process(COMMAND ${CMAKE_COMMAND} -E sleep 2)
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/b.cmake)

# --- G1. status ---------------------------------------------------------------
run_cache(rc log status)
string(FIND "${log}" "a-1.0-${SA}" _a)
string(FIND "${log}" "archives/sha256/${HA}" _arch)
string(FIND "${log}" "4 entries" _n)
check("rc EQUAL 0 AND NOT _a EQUAL -1 AND NOT _arch EQUAL -1 AND NOT _n EQUAL -1" "status lists source entries and archives with a total")

# --- G2. dry run deletes nothing ------------------------------------------------
run_cache(rc log gc -DCMDEP_GC_OLDER_THAN=1s -DCMDEP_GC_DRY_RUN=ON)
string(FIND "${log}" "would remove" _would)
check("rc EQUAL 0 AND NOT _would EQUAL -1 AND EXISTS \"${DA}\" AND EXISTS \"${DB}\"" "gc --dry-run reports but deletes nothing")

# --- G3. size limit removes least recently used first ---------------------------
# Limit = current total - 1: gc must evict exactly the least recently used
# removable item (a's entry; fresh archives are protected for an hour).
include("${_repo}/cmake/CmDepCache.cmake")
set(_total 0)
foreach (_p "${DA}" "${DB}" "${CACHE_DIR}/archives/sha256/${HA}" "${CACHE_DIR}/archives/sha256/${HB}")
    _CmDepPathSize(_sz "${_p}")
    math(EXPR _total "${_total} + ${_sz}")
endforeach ()
math(EXPR _limit "${_total} - 1")
run_cache(rc log gc -DCMDEP_GC_OLDER_THAN=3650d -DCMDEP_GC_MAX_SIZE=${_limit})
check("rc EQUAL 0 AND NOT EXISTS \"${DA}\" AND EXISTS \"${DB}\"" "gc --max-size evicts the least recently used entry")
file(GLOB _trash "${CACHE_DIR}/.tmp/gc-*")
check("NOT _trash" "gc leaves no trash behind")

# --- G4. locked entries are skipped --------------------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/a.cmake)
file(MAKE_DIRECTORY "${CACHE_DIR}/.locks")
file(WRITE "${WORK_DIR}/hold.cmake"
    "file(LOCK \"${CACHE_DIR}/.locks/a-1.0-${SA}.lock\" GUARD PROCESS)\n"
    "execute_process(COMMAND \${CMAKE_COMMAND} -E sleep 3)\n")
file(WRITE "${WORK_DIR}/gc-locked.cmake"
    "execute_process(COMMAND \${CMAKE_COMMAND} -E sleep 1)\n"
    "execute_process(COMMAND \${CMAKE_COMMAND} -E env CMDEP_CONFIG=${WORK_DIR}/no-such-config.cmake \${CMAKE_COMMAND} -DCMDEP_DIR=${CACHE_DIR} -DCMDEP_CACHE_ACTION=gc -DCMDEP_GC_OLDER_THAN=0s -P ${_repo}/cmake/CmDepCache.cmake OUTPUT_QUIET ERROR_QUIET)\n")
execute_process(COMMAND ${CMAKE_COMMAND} -E sleep 1)
execute_process(
    COMMAND ${CMAKE_COMMAND} -P "${WORK_DIR}/hold.cmake"
    COMMAND ${CMAKE_COMMAND} -P "${WORK_DIR}/gc-locked.cmake")
check("EXISTS \"${DA}/.cmake-dep-complete\" AND NOT EXISTS \"${DB}\"" "gc skips an entry locked by a running configure, removes the rest")

# --- G5. verify finds and removes corrupt archives -------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/b.cmake)
file(WRITE "${CACHE_DIR}/archives/sha256/${HB}" "corrupted")
run_cache(rc log verify -DCMDEP_GC_DRY_RUN=ON)
string(FIND "${log}" "CORRUPT archives/sha256/${HB}" _c)
check("NOT _c EQUAL -1 AND EXISTS \"${CACHE_DIR}/archives/sha256/${HB}\"" "verify --dry-run reports a corrupt archive")
run_cache(rc log verify)
check("NOT EXISTS \"${CACHE_DIR}/archives/sha256/${HB}\"" "verify removes the corrupt archive")

if (PYTHON3)
    # --- G6. incomplete entries and abandoned temp dirs ---------------------------
    file(MAKE_DIRECTORY "${CACHE_DIR}/zombie-1.0-000000000000" "${CACHE_DIR}/.tmp/zombie-1.0-000000000000")
    set_mtime("${CACHE_DIR}/zombie-1.0-000000000000" 7200)
    set_mtime("${CACHE_DIR}/.tmp/zombie-1.0-000000000000" 172800)
    file(MAKE_DIRECTORY "${CACHE_DIR}/fresh-1.0-000000000000")   # incomplete but recent: may be in progress
    run_cache(rc log verify -DCMDEP_GC_DRY_RUN=ON)
    string(FIND "${log}" "INCOMPLETE zombie-1.0-000000000000" _inc)
    check("NOT _inc EQUAL -1" "verify reports incomplete entries")
    run_cache(rc log gc)
    check("NOT EXISTS \"${CACHE_DIR}/zombie-1.0-000000000000\" AND NOT EXISTS \"${CACHE_DIR}/.tmp/zombie-1.0-000000000000\"" "gc removes old incomplete entries and abandoned temp dirs")
    check("EXISTS \"${CACHE_DIR}/fresh-1.0-000000000000\"" "gc keeps recent incomplete entries")
    check("EXISTS \"${DA}/.cmake-dep-complete\"" "default gc (90d) keeps recently used entries")

    # --- G7. a cache hit refreshes last-used --------------------------------------
    set_mtime("${DA}/.cmake-dep-complete" 864000)   # 10 days ago
    run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/a.cmake)
    file(TIMESTAMP "${DA}/.cmake-dep-complete" _t "%s" UTC)
    string(TIMESTAMP _now "%s" UTC)
    math(EXPR _age "${_now} - ${_t}")
    check("_age LESS 600" "cache hit refreshes the entry's last-used time")
    set_mtime("${DA}/.cmake-dep-complete" 864000)
    run_cache(rc log gc -DCMDEP_GC_OLDER_THAN=5d)
    check("NOT EXISTS \"${DA}\"" "gc --older-than removes entries unused for longer")
else ()
    message(STATUS "SKIP: timestamp-based gc tests (python3 not found)")
endif ()

if (RESULT_FILE)
    file(WRITE "${RESULT_FILE}" "${_failures}")
endif ()
if (_failures GREATER 0)
    message(FATAL_ERROR "${_failures} cache test(s) failed")
endif ()
message(STATUS "All cache tests passed")
