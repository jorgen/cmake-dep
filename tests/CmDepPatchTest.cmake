# Tests for CmDepFetchPackage(... PATCHES ...). Run with:
#   cmake -P tests/CmDepPatchTest.cmake   (also run by CmDepFetchTest.cmake; needs git)
cmake_minimum_required(VERSION 3.18)

get_filename_component(_repo "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if (NOT WORK_DIR)
    set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/cmdep-patch-test-work")
endif ()
file(TO_CMAKE_PATH "${WORK_DIR}" WORK_DIR)
file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")
set(CACHE_DIR "${WORK_DIR}/cache")
include("${CMAKE_CURRENT_LIST_DIR}/CmDepTestHelpers.cmake" NO_POLICY_SCOPE)
if (RESULT_FILE)
    file(WRITE "${RESULT_FILE}" "1")
endif ()

make_archive(TGZ H "dep-1.0" "set(DEP_VALUE original)\n")
string(SUBSTRING "${H}" 0 12 S)
set(BASE "${CACHE_DIR}/dep-1.0-${S}")

file(MAKE_DIRECTORY "${WORK_DIR}/proj/patches")
file(WRITE "${WORK_DIR}/proj/patches/0001-value.patch"
"diff --git a/CMakeLists.txt b/CMakeLists.txt
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -1 +1 @@
-set(DEP_VALUE original)
+set(DEP_VALUE patched)
")
file(WRITE "${WORK_DIR}/proj/patches/0002-newfile.patch"
"diff --git a/added.txt b/added.txt
new file mode 100644
--- /dev/null
+++ b/added.txt
@@ -0,0 +1 @@
+hello
")
file(WRITE "${WORK_DIR}/proj/patches/bad.patch"
"diff --git a/CMakeLists.txt b/CMakeLists.txt
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -1 +1 @@
-this line does not exist
+set(DEP_VALUE broken)
")
file(WRITE "${WORK_DIR}/proj/packages.cmake"
    "CmDepFetchPackage(dep 1.0 \"${FU}${TGZ}\" SHA256=${H}\n"
    "    PATCHES patches/0001-value.patch patches/0002-newfile.patch)\n")
file(WRITE "${WORK_DIR}/proj/one-patch.cmake"
    "CmDepFetchPackage(dep 1.0 \"${FU}${TGZ}\" SHA256=${H} PATCHES patches/0001-value.patch)\n")
file(WRITE "${WORK_DIR}/proj/bad.cmake"
    "CmDepFetchPackage(dep 1.0 \"${FU}${TGZ}\" SHA256=${H} PATCHES patches/bad.patch)\n")

# --- P1. patches applied into a separate entry ---------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/proj/packages.cmake)
file(GLOB _patched "${BASE}-p*")
list(LENGTH _patched _np)
check("rc EQUAL 0 AND _np EQUAL 1" "patched tree is its own cache entry")
list(GET _patched 0 P1)
file(READ "${P1}/CMakeLists.txt" _c)
check("_c STREQUAL \"set(DEP_VALUE patched)\\n\" AND EXISTS \"${P1}/added.txt\"" "both patches applied in order (edit + new file)")
file(READ "${BASE}/CMakeLists.txt" _b)
check("_b STREQUAL \"set(DEP_VALUE original)\\n\"" "shared unpatched entry left untouched")
file(STRINGS "${P1}/.cmake-dep-complete" _st REGEX "^patch=")
list(LENGTH _st _nst)
check("_nst EQUAL 2" "stamp records the applied patches")

# --- P2. cache hit ------------------------------------------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/proj/packages.cmake)
string(FIND "${log}" "applied" _ap)
check("rc EQUAL 0 AND _ap EQUAL -1" "second run reuses the patched entry")

# --- P3. different patch set -> different entry ---------------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/proj/one-patch.cmake)
file(GLOB _patched "${BASE}-p*")
list(LENGTH _patched _np)
check("rc EQUAL 0 AND _np EQUAL 2" "a different patch set gets a separate entry")

# --- P4. a patch that does not apply ------------------------------------------------------
run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/proj/bad.cmake)
string(FIND "${log}" "does not apply" _na)
file(GLOB _patched "${BASE}-p*")
list(LENGTH _patched _np)
file(GLOB _tmp "${CACHE_DIR}/.tmp/*")
check("NOT rc EQUAL 0 AND NOT _na EQUAL -1 AND _np EQUAL 2 AND NOT _tmp" "failing patch: clear error, no entry, no temp dir")

# --- P5. cache inside a git repository (CMDEP_DIR=3rdparty in a project) ----------------
find_program(GIT git)
if (GIT)
    set(_gitproj "${WORK_DIR}/gitproj")
    file(MAKE_DIRECTORY "${_gitproj}")
    execute_process(COMMAND "${GIT}" init -q WORKING_DIRECTORY "${_gitproj}")
    file(WRITE "${_gitproj}/CMakeLists.txt" "# the project's own file -- must not be patched\n")
    set(_saved "${CACHE_DIR}")
    set(CACHE_DIR "${_gitproj}/3rdparty")
    run_fetch(rc log -DCMDEP_PACKAGES_FILE=${WORK_DIR}/proj/packages.cmake)
    file(GLOB _patched "${CACHE_DIR}/dep-1.0-${S}-p*")
    set(_ok FALSE)
    if (rc EQUAL 0 AND _patched)
        list(GET _patched 0 _pp)
        file(READ "${_pp}/CMakeLists.txt" _c)
        file(READ "${_gitproj}/CMakeLists.txt" _own)
        if (_c STREQUAL "set(DEP_VALUE patched)\n" AND _own MATCHES "must not be patched")
            set(_ok TRUE)
        endif ()
    endif ()
    check("_ok" "patching inside an enclosing git repository patches the dependency, not the repo")
    set(CACHE_DIR "${_saved}")
endif ()

# --- P6. configure mode ------------------------------------------------------------------
file(WRITE "${WORK_DIR}/proj/CMakeLists.txt" "
cmake_minimum_required(VERSION 3.18)
project(proj NONE)
list(APPEND CMAKE_MODULE_PATH \"${_repo}/cmake\")
include(CmDepMain)
set(CMDEP_PACKAGES_FILE \"\${CMAKE_CURRENT_SOURCE_DIR}/packages.cmake\")
CmDepFetch()
include(\"\${dep_SOURCE_DIR}/CMakeLists.txt\")
if (NOT DEP_VALUE STREQUAL \"patched\")
  message(FATAL_ERROR \"DEP_VALUE=\${DEP_VALUE}\")
endif ()
")
execute_process(COMMAND ${CMAKE_COMMAND} -E env CMDEP_CONFIG=${WORK_DIR}/no-such-config.cmake
        ${CMAKE_COMMAND} -S "${WORK_DIR}/proj" -B "${WORK_DIR}/proj/build" -DCMDEP_DIR=${CACHE_DIR}
    RESULT_VARIABLE rc OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
set(log "${_o}${_e}")
check("rc EQUAL 0" "configure mode: <name>_SOURCE_DIR points at the patched tree")

if (RESULT_FILE)
    file(WRITE "${RESULT_FILE}" "${_failures}")
endif ()
if (_failures GREATER 0)
    message(FATAL_ERROR "${_failures} patch test(s) failed")
endif ()
message(STATUS "All patch tests passed")
