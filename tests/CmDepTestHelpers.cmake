# Shared helpers for the cmake-dep test scripts. Expects _repo, WORK_DIR and
# CACHE_DIR to be set by the including script.

# Prefix that turns an absolute path into a file:// URL ("file:///C:/x" on Windows).
if (WIN32)
    set(FU "file:///")
else ()
    set(FU "file://")
endif ()

if (NOT DEFINED _failures)
    set(_failures 0)
endif ()

# check("<if() condition>" "description")
macro(check cond msg)
    cmake_language(EVAL CODE "if (${cond})\n set(_chk TRUE)\nelse ()\n set(_chk FALSE)\nendif ()")
    if (_chk)
        message(STATUS "PASS: ${msg}")
    else ()
        message(STATUS "FAIL: ${msg}")
        math(EXPR _failures "${_failures} + 1")
        # Show the tail of the most recent command output to make remote (CI)
        # failures diagnosable.
        if (DEFINED log AND NOT "${log}" STREQUAL "")
            string(LENGTH "${log}" _loglen)
            set(_logtail "${log}")
            if (_loglen GREATER 3000)
                math(EXPR _logstart "${_loglen} - 3000")
                string(SUBSTRING "${log}" ${_logstart} -1 _logtail)
            endif ()
            message(STATUS "---- last command output (tail) ----\n${_logtail}\n------------------------------------")
        endif ()
    endif ()
endmacro()

# make_archive(<out_path_var> <out_hash_var> <top-level dir name> <CMakeLists content>)
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

# run_fetch(<rc_var> <log_var> [-D...]...)
# Runs the standalone fetcher against CACHE_DIR in a clean environment: no user
# config file and no CMDEP_* environment, plus whatever VAR=VALUE pairs are in
# the RUN_ENV variable.
function(run_fetch out_rc out_log)
    _run_cmdep_script(_rc _log "${_repo}/cmake/CmDepFetchDependencies.cmake" ${ARGN})
    set(${out_rc} "${_rc}" PARENT_SCOPE)
    set(${out_log} "${_log}" PARENT_SCOPE)
endfunction()

# run_mirror(<rc_var> <log_var> [-D...]...) -- same, for CmDepMirror.cmake
function(run_mirror out_rc out_log)
    _run_cmdep_script(_rc _log "${_repo}/cmake/CmDepMirror.cmake" ${ARGN})
    set(${out_rc} "${_rc}" PARENT_SCOPE)
    set(${out_log} "${_log}" PARENT_SCOPE)
endfunction()

function(_run_cmdep_script out_rc out_log script)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E env
                --unset=CMDEP_DIR --unset=CMDEP_MIRRORS --unset=CMDEP_MIRROR_PUSH
                --unset=CMDEP_KEEP_ARCHIVES --unset=CMDEP_MIRROR_TIMEOUT
                --unset=CMDEP_MIRROR_HTTPHEADER
                CMDEP_CONFIG=${WORK_DIR}/no-such-config.cmake ${RUN_ENV}
                ${CMAKE_COMMAND} -DCMDEP_DIR=${CACHE_DIR} -DCMDEP_PROJECT=proj ${ARGN}
                -P "${script}"
        RESULT_VARIABLE _rc OUTPUT_VARIABLE _out ERROR_VARIABLE _err)
    set(${out_rc} "${_rc}" PARENT_SCOPE)
    set(${out_log} "${_out}${_err}" PARENT_SCOPE)
endfunction()

# count_matches(<out_var> <haystack> <needle>)
function(count_matches out_var haystack needle)
    set(_n 0)
    string(FIND "${haystack}" "${needle}" _p)
    while (NOT _p EQUAL -1)
        math(EXPR _n "${_n} + 1")
        string(LENGTH "${needle}" _len)
        math(EXPR _p "${_p} + ${_len}")
        string(SUBSTRING "${haystack}" ${_p} -1 haystack)
        string(FIND "${haystack}" "${needle}" _p)
    endwhile ()
    set(${out_var} ${_n} PARENT_SCOPE)
endfunction()
