# Tests for git dependencies (CmDepFetchGit, cmdep add --git). Run with:
#   cmake -P tests/CmDepGitTest.cmake   (also run by CmDepFetchTest.cmake; needs git)
cmake_minimum_required(VERSION 3.18)

get_filename_component(_repo "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if (NOT WORK_DIR)
    set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/cmdep-git-test-work")
endif ()
file(TO_CMAKE_PATH "${WORK_DIR}" WORK_DIR)
file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")
set(CACHE_DIR "${WORK_DIR}/cache")
include("${CMAKE_CURRENT_LIST_DIR}/CmDepTestHelpers.cmake" NO_POLICY_SCOPE)
if (RESULT_FILE)
    file(WRITE "${RESULT_FILE}" "1")
endif ()
find_program(GIT git)
if (NOT GIT)
    message(STATUS "SKIP: git tests (git not found)")
    if (RESULT_FILE)
        file(WRITE "${RESULT_FILE}" "0")
    endif ()
    return()
endif ()

# --- fixture repository: two commits, a tag on the first ------------------------
set(UP "${WORK_DIR}/upstream")
file(MAKE_DIRECTORY "${UP}")
function(g)
    execute_process(COMMAND "${GIT}" -c user.name=t -c user.email=t@t -c init.defaultBranch=main ${ARGN}
        WORKING_DIRECTORY "${UP}" RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
    if (NOT _r EQUAL 0)
        message(FATAL_ERROR "git ${ARGN}: ${_o}${_e}")
    endif ()
    string(STRIP "${_o}" _o)
    set(G_OUT "${_o}" PARENT_SCOPE)
endfunction()
g(init -q)
file(WRITE "${UP}/CMakeLists.txt" "set(GITDEP_VALUE one)\n")
file(WRITE "${UP}/sub/file.txt" "x\n")
g(add -A)
g(commit -q -m one)
g(tag -a v1.0 -m "release 1.0")
g(rev-parse HEAD)
set(C1 "${G_OUT}")
file(WRITE "${UP}/CMakeLists.txt" "set(GITDEP_VALUE two)\n")
g(commit -q -am two)
g(rev-parse HEAD)
set(C2 "${G_OUT}")
set(UPURL "${FU}${UP}")

file(WRITE "${WORK_DIR}/unpinned.cmake" "CmDepFetchGit(gitdep 1.0 \"${UPURL}\" ${C1})\n")

# --- T1. unpinned: fetched with git, pin printed -------------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/unpinned.cmake)
string(REGEX MATCH "add SHA256=([0-9a-f]+)" _m "${log}")
set(HG "${CMAKE_MATCH_1}")
check("rc EQUAL 0 AND HG" "unpinned git dependency fetched; the pin is printed")
string(SUBSTRING "${HG}" 0 12 SG)
set(DG "${CACHE_DIR}/gitdep-1.0-${SG}")
file(READ "${DG}/CMakeLists.txt" _c)
check("_c STREQUAL \"set(GITDEP_VALUE one)\\n\" AND EXISTS \"${DG}/sub/file.txt\"" "tree is the pinned commit (not the branch tip)")
check("EXISTS \"${CACHE_DIR}/archives/sha256/${HG}\" AND EXISTS \"${CACHE_DIR}/git/${C1}.sha256\"" "archive stored and commit indexed")

# --- T2. the archive hash is a pure function of the commit ---------------------------
execute_process(COMMAND "${GIT}" -c core.autocrlf=false -c core.eol=lf -c tar.umask=0022
        archive --format=tar --prefix=source/ -o "${WORK_DIR}/manual.tar" ${C1} WORKING_DIRECTORY "${UP}")
file(SHA256 "${WORK_DIR}/manual.tar" _manual)
check("_manual STREQUAL HG" "hash equals `git archive --format=tar --prefix=source/ <commit>`")

# --- T3. pinned: works from mirrors without git access ---------------------------------
file(WRITE "${WORK_DIR}/pinned.cmake" "CmDepFetchGit(gitdep 1.0 \"${UPURL}\" ${C1} SHA256=${HG})\n")
file(WRITE "${WORK_DIR}/pinned-unreachable.cmake"
    "CmDepFetchGit(gitdep 1.0 \"${FU}${WORK_DIR}/no-such-repo\" ${C1} SHA256=${HG})\n")
run_mirror(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/pinned.cmake -DCMDEP_MIRROR_OUT=${WORK_DIR}/mirror)
check("rc EQUAL 0 AND EXISTS \"${WORK_DIR}/mirror/sha256/${HG}\"" "pinned git dependency can be mirrored")
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/pinned-unreachable.cmake "-DCMDEP_MIRRORS=${WORK_DIR}/mirror")
check("rc EQUAL 0 AND EXISTS \"${DG}/CMakeLists.txt\"" "pinned git dependency served by a mirror, repository not needed")

# --- T4. pinned, direct: cloned and verified --------------------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/pinned.cmake)
string(FIND "${log}" "fetching ${UPURL} at ${C1}" _f)
check("rc EQUAL 0 AND NOT _f EQUAL -1 AND EXISTS \"${DG}/CMakeLists.txt\"" "pinned git dependency cloned directly and verified")
file(WRITE "${WORK_DIR}/wrong.cmake" "CmDepFetchGit(gitdep 1.0 \"${UPURL}\" ${C2} SHA256=${HG})\n")
file(REMOVE_RECURSE "${CACHE_DIR}")  # the hash, not the commit, keys the cache
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/wrong.cmake)
string(FIND "${log}" "re-pin" _rp)
check("NOT rc EQUAL 0 AND NOT _rp EQUAL -1" "hash/commit mismatch is an error with a hint")

# --- T5. validation ----------------------------------------------------------------------
file(WRITE "${WORK_DIR}/tag.cmake" "CmDepFetchGit(gitdep 1.0 \"${UPURL}\" v1.0)\n")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/tag.cmake)
string(FIND "${log}" "not a full commit id" _nf)
check("NOT rc EQUAL 0 AND NOT _nf EQUAL -1" "tags/branches are rejected in CmDepFetchGit")
file(REMOVE_RECURSE "${CACHE_DIR}")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/unpinned.cmake "-DCMDEP_MIRRORS=${WORK_DIR}/mirror")
string(FIND "${log}" "'direct' is not in CMDEP_MIRRORS" _nd)
check("NOT rc EQUAL 0 AND NOT _nd EQUAL -1" "unpinned git dependency refused in mirrors-only mode")

# --- T6. cmdep add --git resolves a tag and pins it ----------------------------------------
if (WIN32)
    set(CMDEP "${_repo}/bin/cmdep.cmd")
else ()
    set(CMDEP "${_repo}/bin/cmdep")
endif ()
file(MAKE_DIRECTORY "${WORK_DIR}/addproj")
execute_process(
    COMMAND ${CMAKE_COMMAND} -E env CMDEP_CONFIG=${WORK_DIR}/no-such-config.cmake CMDEP_DIR=${CACHE_DIR}
            CMAKE=${CMAKE_COMMAND} "${CMDEP}" add gitdep 1.0 "${UPURL}" --git v1.0
    WORKING_DIRECTORY "${WORK_DIR}/addproj" RESULT_VARIABLE rc OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
set(log "${_o}${_e}")
file(READ "${WORK_DIR}/addproj/cmdep-packages.cmake" _pk)
string(FIND "${_pk}" "${C1}" _hasc)
string(FIND "${_pk}" "SHA256=${HG}" _hash)
check("rc EQUAL 0 AND NOT _hasc EQUAL -1 AND NOT _hash EQUAL -1" "cmdep add --git v1.0 pins the tag's commit and hash")
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/addproj/cmdep-packages.cmake)
check("rc EQUAL 0" "the added git dependency fetches")

if (RESULT_FILE)
    file(WRITE "${RESULT_FILE}" "${_failures}")
endif ()
if (_failures GREATER 0)
    message(FATAL_ERROR "${_failures} git test(s) failed")
endif ()
message(STATUS "All git tests passed")
