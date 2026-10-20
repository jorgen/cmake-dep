# Tests for binary packages (CmDepBinaryPackage). Run with:
#   cmake -P tests/CmDepBinaryTest.cmake
# (also run by tests/CmDepFetchTest.cmake). Needs a C compiler; no network.
cmake_minimum_required(VERSION 3.18)

get_filename_component(_repo "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if (NOT WORK_DIR)
    set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/cmdep-binary-test-work")
endif ()
file(TO_CMAKE_PATH "${WORK_DIR}" WORK_DIR)  # e.g. D:\a\_temp on Windows CI
file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")
set(CACHE_DIR "${WORK_DIR}/cache")
include("${CMAKE_CURRENT_LIST_DIR}/CmDepTestHelpers.cmake")
if (RESULT_FILE)
    file(WRITE "${RESULT_FILE}" "1")
endif ()

# --- fixture: a small relocatable C library ---------------------------------
set(_lib "${WORK_DIR}/src/mylib-1.0")
file(MAKE_DIRECTORY "${_lib}")
file(WRITE "${_lib}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.18)
project(mylib C)
set(MYLIB_VALUE 42 CACHE STRING "value baked into the library")
option(MYLIB_ABSOLUTE "write the absolute install prefix into the config (not relocatable)" OFF)
add_library(mylib STATIC mylib.c)
set_target_properties(mylib PROPERTIES DEBUG_POSTFIX d)
target_include_directories(mylib PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}> $<INSTALL_INTERFACE:include>)
target_compile_definitions(mylib PRIVATE MYLIB_VALUE=${MYLIB_VALUE})
install(TARGETS mylib EXPORT mylibTargets ARCHIVE DESTINATION lib)
install(FILES mylib.h DESTINATION include)
install(EXPORT mylibTargets NAMESPACE mylib:: DESTINATION lib/cmake/mylib)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/mylibConfig.cmake"
    "include(\"\${CMAKE_CURRENT_LIST_DIR}/mylibTargets.cmake\")\n")
if (MYLIB_ABSOLUTE)
    file(APPEND "${CMAKE_CURRENT_BINARY_DIR}/mylibConfig.cmake"
        "set(MYLIB_ROOT \"${CMAKE_INSTALL_PREFIX}\")\n"
        "if (NOT EXISTS \"\${MYLIB_ROOT}/include/mylib.h\")\n"
        "  message(FATAL_ERROR \"MYLIB_ROOT points nowhere: \${MYLIB_ROOT}\")\n"
        "endif ()\n")
endif ()
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/mylibConfig.cmake" DESTINATION lib/cmake/mylib)
]=])
file(WRITE "${_lib}/mylib.h" "int mylib_value(void);\n")
file(WRITE "${_lib}/mylib.c" "#include \"mylib.h\"\nint mylib_value(void) { return MYLIB_VALUE; }\n")
execute_process(COMMAND ${CMAKE_COMMAND} -E tar czf "${WORK_DIR}/mylib-1.0.tar.gz" mylib-1.0
    WORKING_DIRECTORY "${WORK_DIR}/src")
file(SHA256 "${WORK_DIR}/mylib-1.0.tar.gz" HLIB)
file(WRITE "${WORK_DIR}/packages.cmake"
    "CmDepFetchPackage(mylib 1.0 \"${FU}${WORK_DIR}/mylib-1.0.tar.gz\" SHA256=${HLIB})\n")

# --- consumer project ---------------------------------------------------------
set(_consumer "${WORK_DIR}/consumer")
file(MAKE_DIRECTORY "${_consumer}")
file(WRITE "${_consumer}/CMakeLists.txt" "
cmake_minimum_required(VERSION 3.18)
project(consumer C)
list(APPEND CMAKE_MODULE_PATH \"${_repo}/cmake\")
include(CmDepMain)
set(CMDEP_PACKAGES_FILE \"${WORK_DIR}/packages.cmake\")
CmDepFetch()
if (NOT DEFINED VALUE)
  set(VALUE 42)
endif ()
set(_opts \"\")
if (BIN_GENERATOR)
  list(APPEND _opts GENERATOR \"\${BIN_GENERATOR}\")
endif ()
if (BIN_STRICT)
  list(APPEND _opts NO_PATH_REWRITE)
endif ()
if (BIN_CONFIGS)
  string(REPLACE \",\" \";\" BIN_CONFIGS \"\${BIN_CONFIGS}\")
  list(APPEND _opts CONFIGS \${BIN_CONFIGS})
endif ()
CmDepBinaryPackage(mylib
    CMAKE_ARGS -DMYLIB_VALUE=\${VALUE} \${EXTRA_ARGS}
    FIND_PACKAGE mylib REQUIRED
    \${_opts})
if (NOT TARGET mylib::mylib)
  message(FATAL_ERROR \"mylib::mylib missing\")
endif ()
file(WRITE \"\${CMAKE_BINARY_DIR}/prefix.txt\" \"\${mylib_BINARY_PREFIX}\")
add_executable(consumer main.c)
target_link_libraries(consumer PRIVATE mylib::mylib)
target_compile_definitions(consumer PRIVATE EXPECT=\${VALUE})
")
file(WRITE "${_consumer}/main.c"
    "#include <mylib.h>\n#include <stdio.h>\nint main(void) { printf(\"%d\\n\", mylib_value()); return mylib_value() == EXPECT ? 0 : 1; }\n")

# configure_consumer(<rc> <log> <build-dir> [-D...]...) -- clean environment + RUN_ENV
function(configure_consumer out_rc out_log bdir)
    file(REMOVE_RECURSE "${bdir}")
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E env
                --unset=CMDEP_DIR --unset=CMDEP_MIRRORS --unset=CMDEP_BINARIES
                --unset=CMDEP_BINARY_MIRRORS --unset=CMDEP_BINARY_PUSH --unset=CMDEP_BINARY_PLATFORM
                CMDEP_CONFIG=${WORK_DIR}/no-such-config.cmake ${RUN_ENV}
                ${CMAKE_COMMAND} -S "${_consumer}" -B "${bdir}" -DCMAKE_BUILD_TYPE=Release
                -DCMDEP_DIR=${CACHE_DIR} ${ARGN}
        RESULT_VARIABLE _rc OUTPUT_VARIABLE _out ERROR_VARIABLE _err)
    set(${out_rc} "${_rc}" PARENT_SCOPE)
    set(${out_log} "${_out}${_err}" PARENT_SCOPE)
endfunction()

# build_and_run(<ok_var> <build-dir>)
function(build_and_run out_ok bdir)
    execute_process(COMMAND ${CMAKE_COMMAND} --build "${bdir}" RESULT_VARIABLE _r OUTPUT_QUIET ERROR_QUIET)
    if (_r EQUAL 0)
        find_program(_exe consumer PATHS "${bdir}" "${bdir}/Debug" "${bdir}/Release" NO_DEFAULT_PATH NO_CACHE)
        execute_process(COMMAND "${_exe}" RESULT_VARIABLE _r OUTPUT_QUIET)
    endif ()
    if (_r EQUAL 0)
        set(${out_ok} TRUE PARENT_SCOPE)
    else ()
        set(${out_ok} FALSE PARENT_SCOPE)
    endif ()
endfunction()

set(BMIRROR "${WORK_DIR}/bin-mirror")

# --- B1. first configure builds the package into the shared cache -----------
configure_consumer(rc log "${WORK_DIR}/b1")
string(FIND "${log}" "building it now" _built)
check("rc EQUAL 0 AND NOT _built EQUAL -1" "first configure builds the binary package")
file(READ "${WORK_DIR}/b1/prefix.txt" P1)
check("EXISTS \"${P1}/.cmake-dep-complete\" AND EXISTS \"${P1}/.cmake-dep-binary.txt\"" "prefix stamped, build inputs recorded")
string(FIND "${P1}" "${CACHE_DIR}/bin/mylib-1.0-" _inbin)
check("_inbin EQUAL 0" "prefix lives in <cache>/bin/<name>-<version>-<key12>")
build_and_run(ok "${WORK_DIR}/b1")
check("ok" "consumer links against the binary package and runs")
file(GLOB _left "${CACHE_DIR}/.tmp/*")
check("NOT _left" "no temp dirs left behind")

# --- B2. another build dir / checkout is a cache hit ------------------------
configure_consumer(rc log "${WORK_DIR}/b2")
string(FIND "${log}" "building it now" _built)
file(READ "${WORK_DIR}/b2/prefix.txt" P2)
check("rc EQUAL 0 AND _built EQUAL -1 AND P2 STREQUAL P1" "second build dir reuses the same prefix without building")
build_and_run(ok "${WORK_DIR}/b2")
check("ok" "consumer builds from the cached prefix")

# --- B3. changing CMAKE_ARGS changes the key ---------------------------------
configure_consumer(rc log "${WORK_DIR}/b3" -DVALUE=7)
file(READ "${WORK_DIR}/b3/prefix.txt" P3)
check("rc EQUAL 0 AND NOT P3 STREQUAL P1" "different CMAKE_ARGS -> different key and prefix")
build_and_run(ok "${WORK_DIR}/b3")
check("ok" "rebuilt package carries the new setting")

# --- B4. platform override changes the key -----------------------------------
configure_consumer(rc log "${WORK_DIR}/b4" -DCMDEP_BINARY_PLATFORM=team-image-1)
file(READ "${WORK_DIR}/b4/prefix.txt" P4)
check("rc EQUAL 0 AND NOT P4 STREQUAL P1" "CMDEP_BINARY_PLATFORM changes the key")

# --- B5. push to a binary mirror ----------------------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}" "${BMIRROR}")
configure_consumer(rc log "${WORK_DIR}/b5" "-DCMDEP_BINARY_PUSH=${BMIRROR}")
file(GLOB _tars "${BMIRROR}/bin/*.tar.zst")
file(GLOB _shas "${BMIRROR}/bin/*.tar.zst.sha256")
list(LENGTH _tars _nt)
check("rc EQUAL 0 AND _nt EQUAL 1 AND _shas" "local build pushed as bin/<key>.tar.zst + .sha256")
file(READ "${WORK_DIR}/b5/prefix.txt" P5)
file(STRINGS "${P5}/.cmake-dep-binary.txt" _key REGEX "^key=")
string(REGEX REPLACE "^key=" "" KEY5 "${_key}")
check("EXISTS \"${BMIRROR}/bin/${KEY5}.tar.zst\"" "mirror file named by the full build key")

# --- B6. fresh machine pulls from the mirror instead of building -------------
file(REMOVE_RECURSE "${CACHE_DIR}")
configure_consumer(rc log "${WORK_DIR}/b6" "-DCMDEP_BINARY_MIRRORS=${BMIRROR}")
string(FIND "${log}" "building it now" _built)
string(FIND "${log}" "downloading binary from ${BMIRROR}" _dl)
check("rc EQUAL 0 AND _built EQUAL -1 AND NOT _dl EQUAL -1" "binary fetched from mirror, no local build")
build_and_run(ok "${WORK_DIR}/b6")
check("ok" "consumer builds against the mirrored binary")
file(READ "${WORK_DIR}/b6/prefix.txt" P6)
file(STRINGS "${P6}/.cmake-dep-complete" _src)
check("_src STREQUAL \"source=${BMIRROR}\"" "stamp records the mirror as source")

# --- B7. require mode -------------------------------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
configure_consumer(rc log "${WORK_DIR}/b7" -DCMDEP_BINARIES=require "-DCMDEP_BINARY_MIRRORS=${WORK_DIR}/empty")
string(FIND "${log}" "CMDEP_BINARIES=require" _req)
check("NOT rc EQUAL 0 AND NOT _req EQUAL -1" "require mode fails when no binary is available")
configure_consumer(rc log "${WORK_DIR}/b7b" -DCMDEP_BINARIES=require "-DCMDEP_BINARY_MIRRORS=${BMIRROR}")
check("rc EQUAL 0" "require mode succeeds when the mirror has it")

# --- B8. corrupt mirror binary falls back to building ------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
file(WRITE "${BMIRROR}/bin/${KEY5}.tar.zst" "garbage")
configure_consumer(rc log "${WORK_DIR}/b8" "-DCMDEP_BINARY_MIRRORS=${BMIRROR}")
string(FIND "${log}" "unusable" _unusable)
string(FIND "${log}" "building it now" _built)
check("rc EQUAL 0 AND NOT _unusable EQUAL -1 AND NOT _built EQUAL -1" "corrupt mirror binary rejected, built locally instead")

# --- B9. local mode ignores mirrors -------------------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
configure_consumer(rc log "${WORK_DIR}/b9" -DCMDEP_BINARIES=local "-DCMDEP_BINARY_MIRRORS=${BMIRROR}")
string(FIND "${log}" "downloading binary" _dl)
check("rc EQUAL 0 AND _dl EQUAL -1" "CMDEP_BINARIES=local never consults mirrors")

# --- B10. absolute install paths are rewritten (locally and after download) --
file(REMOVE_RECURSE "${CACHE_DIR}" "${BMIRROR}")
configure_consumer(rc log "${WORK_DIR}/b10" "-DEXTRA_ARGS=-DMYLIB_ABSOLUTE=ON" "-DCMDEP_BINARY_PUSH=${BMIRROR}")
check("rc EQUAL 0" "package embedding its install prefix works after the move into the cache")
file(READ "${WORK_DIR}/b10/prefix.txt" P10)
file(READ "${P10}/lib/cmake/mylib/mylibConfig.cmake" _cfg)
string(FIND "${_cfg}" "set(MYLIB_ROOT \"${P10}\")" _rw)
check("NOT _rw EQUAL -1" "embedded prefix rewritten to the cache location")
build_and_run(ok "${WORK_DIR}/b10")
check("ok" "consumer builds against the rewritten package")

set(_saved_cache "${CACHE_DIR}")
set(CACHE_DIR "${WORK_DIR}/other-machine-cache")
file(REMOVE_RECURSE "${CACHE_DIR}")
configure_consumer(rc log "${WORK_DIR}/b10b" "-DEXTRA_ARGS=-DMYLIB_ABSOLUTE=ON" "-DCMDEP_BINARY_MIRRORS=${BMIRROR}")
string(FIND "${log}" "building it now" _built)
check("rc EQUAL 0 AND _built EQUAL -1" "mirrored package extracted under a different cache path")
file(READ "${WORK_DIR}/b10b/prefix.txt" P10b)
file(READ "${P10b}/lib/cmake/mylib/mylibConfig.cmake" _cfg)
string(FIND "${_cfg}" "set(MYLIB_ROOT \"${P10b}\")" _rw)
check("NOT _rw EQUAL -1" "embedded prefix rewritten again for the new location")
set(CACHE_DIR "${_saved_cache}")

file(REMOVE_RECURSE "${CACHE_DIR}")
configure_consumer(rc log "${WORK_DIR}/b10c" "-DEXTRA_ARGS=-DMYLIB_ABSOLUTE=ON" -DBIN_STRICT=ON)
string(FIND "${log}" "not relocatable" _reloc)
string(FIND "${log}" "lib/cmake/mylib/mylibConfig.cmake" _file)
check("NOT rc EQUAL 0 AND NOT _reloc EQUAL -1 AND NOT _file EQUAL -1" "NO_PATH_REWRITE: absolute prefix is an error naming the file")
file(GLOB _bins "${CACHE_DIR}/bin/*")
check("NOT _bins" "rejected package is not added to the cache")

# --- B11. CmDepBinaryPush shares an existing local build -----------------------
file(REMOVE_RECURSE "${CACHE_DIR}" "${BMIRROR}")
configure_consumer(rc log "${WORK_DIR}/b11")
file(READ "${WORK_DIR}/b11/prefix.txt" P11)
execute_process(COMMAND ${CMAKE_COMMAND} -DCMDEP_BINARY_ENTRY=${P11} -DCMDEP_BINARY_PUSH=${FU}${BMIRROR}
        -P "${_repo}/cmake/CmDepBinaryPush.cmake" RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
file(GLOB _shas "${BMIRROR}/bin/*.sha256")
check("rc EQUAL 0 AND _shas" "CmDepBinaryPush uploads an existing cache entry")
file(REMOVE_RECURSE "${CACHE_DIR}")
configure_consumer(rc log "${WORK_DIR}/b11b" "-DCMDEP_BINARY_MIRRORS=${BMIRROR}")
string(FIND "${log}" "building it now" _built)
check("rc EQUAL 0 AND _built EQUAL -1" "pushed entry is usable from the mirror")

# --- B12. concurrent configures build once -----------------------------------
file(REMOVE_RECURSE "${CACHE_DIR}")
foreach (i 1 2)
    file(WRITE "${WORK_DIR}/par${i}.cmake"
        "execute_process(COMMAND \${CMAKE_COMMAND} -E env CMDEP_CONFIG=${WORK_DIR}/no-such-config.cmake \${CMAKE_COMMAND} -S ${_consumer} -B ${WORK_DIR}/par${i} -DCMAKE_BUILD_TYPE=Release -DCMDEP_DIR=${CACHE_DIR} RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)\n"
        "file(WRITE \"${WORK_DIR}/par${i}.log\" \"rc=\${rc}\\n\${out}\${err}\")\n")
endforeach ()
execute_process(
    COMMAND ${CMAKE_COMMAND} -P "${WORK_DIR}/par1.cmake"
    COMMAND ${CMAKE_COMMAND} -P "${WORK_DIR}/par2.cmake")
file(READ "${WORK_DIR}/par1.log" _l1)
file(READ "${WORK_DIR}/par2.log" _l2)
count_matches(_nb "${_l1}${_l2}" "building it now")
string(FIND "${_l1}" "rc=0" _r1)
string(FIND "${_l2}" "rc=0" _r2)
check("_r1 EQUAL 0 AND _r2 EQUAL 0 AND _nb EQUAL 1" "two concurrent configures: both succeed, one builds (built ${_nb}x)")

# --- B13. multi-config parent: Release + Debug in one prefix (Ninja Multi-Config)
file(REMOVE_RECURSE "${CACHE_DIR}")
configure_consumer(rc log "${WORK_DIR}/b13" -G "Ninja Multi-Config")
string(FIND "${log}" "Ninja Multi-Config, multi" _nmc)
file(READ "${WORK_DIR}/b13/prefix.txt" P13)
check("rc EQUAL 0 AND NOT _nmc EQUAL -1" "multi-config parent builds the dependency with Ninja Multi-Config")
file(GLOB _rel "${P13}/lib/*mylib.*")
file(GLOB _dbg "${P13}/lib/*mylibd.*")
check("_rel AND _dbg" "Release and Debug both installed into one prefix")
foreach (_cfg Debug Release)
    execute_process(COMMAND ${CMAKE_COMMAND} --build "${WORK_DIR}/b13" --config ${_cfg}
        RESULT_VARIABLE _r OUTPUT_QUIET ERROR_QUIET)
    if (_r EQUAL 0)
        find_program(_exe consumer PATHS "${WORK_DIR}/b13/${_cfg}" NO_DEFAULT_PATH NO_CACHE)
        execute_process(COMMAND "${_exe}" RESULT_VARIABLE _r OUTPUT_QUIET)
    endif ()
    check("_r EQUAL 0" "consumer ${_cfg} build links the matching configuration")
endforeach ()

# --- B14. single-config generator, several configs: one build dir per config
file(REMOVE_RECURSE "${CACHE_DIR}")
if (WIN32)
    set(_single_gen "NMake Makefiles")
else ()
    set(_single_gen "Unix Makefiles")
endif ()
configure_consumer(rc log "${WORK_DIR}/b14" "-DBIN_GENERATOR=${_single_gen}" -DBIN_CONFIGS=Release,Debug)
file(READ "${WORK_DIR}/b14/prefix.txt" P14)
string(FIND "${log}" "(${_single_gen}, Debug)" _per)
check("rc EQUAL 0 AND NOT _per EQUAL -1" "explicit GENERATOR/CONFIGS: one build dir per config")
file(GLOB _rel "${P14}/lib/*mylib.*")
file(GLOB _dbg "${P14}/lib/*mylibd.*")
check("_rel AND _dbg" "both configs installed with a single-config generator")
build_and_run(ok "${WORK_DIR}/b14")
check("ok" "consumer builds against the per-config install")

if (RESULT_FILE)
    file(WRITE "${RESULT_FILE}" "${_failures}")
endif ()
if (_failures GREATER 0)
    message(FATAL_ERROR "${_failures} binary test(s) failed")
endif ()
message(STATUS "All binary tests passed")
