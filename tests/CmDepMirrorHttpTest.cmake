# HTTP half of the mirror tests. Started by CmDepFetchTest.cmake in the same
# execute_process pipeline as tests/mirror_server.py; not meant to be run alone.
# Writes the number of failures to ${WORK_DIR}/http-failures.
cmake_minimum_required(VERSION 3.18)
get_filename_component(_repo "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(CACHE_DIR "${WORK_DIR}/http-cache")
set(HTTP_ROOT "${WORK_DIR}/http-root")
include("${CMAKE_CURRENT_LIST_DIR}/CmDepTestHelpers.cmake")
file(WRITE "${WORK_DIR}/http-failures" "1")

set(_waited 0)
while (NOT EXISTS "${WORK_DIR}/http-port" AND _waited LESS 100)
    execute_process(COMMAND ${CMAKE_COMMAND} -E sleep 0.1)
    math(EXPR _waited "${_waited} + 1")
endwhile ()
if (NOT EXISTS "${WORK_DIR}/http-port")
    message(STATUS "FAIL: HTTP mirror server did not start")
    return()
endif ()
file(READ "${WORK_DIR}/http-port" _port)
set(BASE "http://127.0.0.1:${_port}")
string(SUBSTRING "${H1}" 0 12 S1)
set(D1 "${CACHE_DIR}/dep-1.0-${S1}")

file(WRITE "${WORK_DIR}/http-packages.cmake"
    "CmDepFetchPackage(dep 1.0 \"${BASE}/upstream/dep.tar.gz\" SHA256=${H1})\n")
file(WRITE "${WORK_DIR}/http-packages2.cmake"
    "CmDepFetchPackage(dep2 1.0 \"${BASE}/upstream/dep2.tar.gz\" SHA256=${H2})\n")
set(AUTH "-DCMDEP_MIRROR_HTTPHEADER=Authorization: Bearer s3cret")

# a. 404 on the mirror -> upstream; result pushed back with HTTP PUT
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/http-packages.cmake
    "-DCMDEP_MIRRORS=${BASE},direct" "-DCMDEP_MIRROR_PUSH=${BASE}" "${AUTH}")
check("rc EQUAL 0 AND EXISTS \"${D1}/CMakeLists.txt\"" "HTTP: mirror 404 falls back to direct")
check("EXISTS \"${HTTP_ROOT}/sha256/${H1}\"" "HTTP: download pushed to mirror via PUT")
check("NOT EXISTS \"${HTTP_ROOT}/LEAKED\"" "HTTP: mirror auth header never sent upstream")

# b. mirrors-only, with credentials
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/http-packages.cmake "-DCMDEP_MIRRORS=${BASE}" "${AUTH}")
string(FIND "${log}" "fetched from mirror ${BASE}" _fm)
check("rc EQUAL 0 AND NOT _fm EQUAL -1" "HTTP: mirrors-only fetch served by the mirror")

# c. without credentials the mirror refuses (401) and mirrors-only fails
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/http-packages.cmake "-DCMDEP_MIRRORS=${BASE}")
check("NOT rc EQUAL 0" "HTTP: missing credentials -> mirror refuses")

# d. CmDepMirror.cmake publishing to an HTTP mirror
run_mirror(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/http-packages2.cmake
    -DCMDEP_MIRROR_OUT=${BASE} "${AUTH}")
check("rc EQUAL 0 AND EXISTS \"${HTTP_ROOT}/sha256/${H2}\"" "HTTP: CmDepMirror populates an HTTP mirror via PUT")

file(DOWNLOAD "${BASE}/shutdown" "${WORK_DIR}/shutdown.txt" STATUS _s)
file(WRITE "${WORK_DIR}/http-failures" "${_failures}")
