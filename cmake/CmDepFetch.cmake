function(_CmDepProjectPrefix out_var)
    if (DEFINED CMDEP_PROJECT AND NOT CMDEP_PROJECT STREQUAL "")
        set(_p "${CMDEP_PROJECT}")
    else ()
        set(_p "${PROJECT_NAME}")
    endif ()
    if (_p STREQUAL "")
        message(WARNING "cmake-dep: CMDEP_PROJECT and PROJECT_NAME are both empty; "
                        "override / USE_SYSTEM knobs will have no prefix.")
    endif ()
    string(TOUPPER "${_p}" _p)
    string(MAKE_C_IDENTIFIER "${_p}" _p)
    set(${out_var} "${_p}" PARENT_SCOPE)
endfunction()

macro(CmDepFetchPackage name version url url_hash)
    _CmDepProjectPrefix(_cmdep_prefix)
    string(TOUPPER "${name}" _cmdep_dep)
    string(MAKE_C_IDENTIFIER "${_cmdep_dep}" _cmdep_dep)

    string(REGEX MATCH "^([^=]+)=(.*)$" _cmdep_hash_m "${url_hash}")
    if (NOT _cmdep_hash_m)
        message(FATAL_ERROR "cmake-dep: hash for '${name}' must be ALGO=HEX, got '${url_hash}'")
    endif ()
    set(_cmdep_algo "${CMAKE_MATCH_1}")
    set(_cmdep_hex "${CMAKE_MATCH_2}")

    set(_cmdep_var_ver "${_cmdep_prefix}_${_cmdep_dep}_VERSION")
    set(_cmdep_var_url "${_cmdep_prefix}_${_cmdep_dep}_URL")
    set(_cmdep_var_hash "${_cmdep_prefix}_${_cmdep_dep}_${_cmdep_algo}")
    set(_cmdep_var_sys "${_cmdep_prefix}_USE_SYSTEM_${_cmdep_dep}")

    set(${_cmdep_var_ver} "${version}" CACHE STRING "Version of ${name} to fetch")
    set(${_cmdep_var_url} "${url}" CACHE STRING "Source archive URL for ${name}")
    set(${_cmdep_var_hash} "${_cmdep_hex}" CACHE STRING "${_cmdep_algo} hash for ${name}")
    option(${_cmdep_var_sys} "Use a system-installed ${name} instead of fetching" OFF)

    set(_cmdep_eff_version "${${_cmdep_var_ver}}")
    set(_cmdep_eff_url "${${_cmdep_var_url}}")
    set(_cmdep_eff_hash "${_cmdep_algo}=${${_cmdep_var_hash}}")
    set(_cmdep_use_system "${${_cmdep_var_sys}}")

    if (CMDEP_DIR)
        set(_cmdep_root "${CMDEP_DIR}")
    else ()
        set(_cmdep_root "${PROJECT_SOURCE_DIR}/3rdparty")
    endif ()
    get_filename_component(_cmdep_root "${_cmdep_root}" ABSOLUTE)
    set(_cmdep_src "${_cmdep_root}/${name}-${_cmdep_eff_version}")

    set(${name}_SOURCE_DIR "${_cmdep_src}" PARENT_SCOPE)
    set(${name}_VERSION "${_cmdep_eff_version}" PARENT_SCOPE)
    set(${name}_USE_SYSTEM "${_cmdep_use_system}" PARENT_SCOPE)

    if (NOT _cmdep_use_system AND NOT (EXISTS "${_cmdep_src}"))
        FetchContent_Populate(${name}
            URL ${_cmdep_eff_url}
            URL_HASH ${_cmdep_eff_hash}
            SOURCE_DIR ${_cmdep_src}
            SUBBUILD_DIR ${_cmdep_root}/CMakeArtifacts/${name}-sub-${_cmdep_eff_version}
            BINARY_DIR ${_cmdep_root}/CMakeArtifacts/${name}-${_cmdep_eff_version})
    endif ()
endmacro()

function(CmDepUseSystem name out_var)
    _CmDepProjectPrefix(_p)
    string(TOUPPER "${name}" _d)
    string(MAKE_C_IDENTIFIER "${_d}" _d)
    if (${_p}_USE_SYSTEM_${_d})
        set(${out_var} ON PARENT_SCOPE)
    else ()
        set(${out_var} OFF PARENT_SCOPE)
    endif ()
endfunction()

macro(CmDepFetchFile name version url destination_name url_hash)
    if (CMDEP_DIR)
        set(_CmDep_3rdPartyDir "${CMDEP_DIR}")
    else ()
        set(_CmDep_3rdPartyDir "${PROJECT_SOURCE_DIR}/3rdparty")
    endif ()
    get_filename_component(thirdParty "${_CmDep_3rdPartyDir}" ABSOLUTE)
    file(MAKE_DIRECTORY ${thirdParty})
    set(SRC_DIR ${thirdParty}/${name}-${version})
    set(${name}_SOURCE_DIR ${SRC_DIR} PARENT_SCOPE)
    set(${name}_VERSION ${version} PARENT_SCOPE)
    set(DESTINATION_FILE "${SRC_DIR}/${destination_name}")
    if (NOT (EXISTS ${DESTINATION_FILE}))
        file(DOWNLOAD ${url} ${DESTINATION_FILE}
            SHOW_PROGRESS
            EXPECTED_HASH ${url_hash}
        )
    endif ()
endmacro()

function(CmDepFetch)
    if (NOT DEFINED CMDEP_PACKAGES_FILE)
        message(FATAL_ERROR "CMDEP_PACKAGES_FILE must be set before calling CmDepFetch()")
    endif ()
    include(FetchContent)
    set(FETCHCONTENT_QUIET OFF)
    include(${CMDEP_PACKAGES_FILE})
endfunction()
