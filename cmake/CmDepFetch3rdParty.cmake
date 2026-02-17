macro(CmDepFetch3rdParty_Package name version url url_hash)
    if (CMDEP_3RD_PARTY_DIR)
        set(_CmDep_3rdPartyDir "${CMDEP_3RD_PARTY_DIR}")
    elseif (POINTS_3RD_PARTY_DIR)
        set(_CmDep_3rdPartyDir "${POINTS_3RD_PARTY_DIR}")
    else ()
        set(_CmDep_3rdPartyDir "${PROJECT_SOURCE_DIR}/3rdparty")
    endif ()
    get_filename_component(thirdParty "${_CmDep_3rdPartyDir}" ABSOLUTE)
    set(SRC_DIR ${thirdParty}/${name}-${version})
    set(${name}_SOURCE_DIR ${SRC_DIR} PARENT_SCOPE)
    set(${name}_VERSION ${version} PARENT_SCOPE)
    if (NOT (EXISTS ${SRC_DIR}))
        FetchContent_Populate(${name}
            URL ${url}
            URL_HASH ${url_hash}
            SOURCE_DIR ${SRC_DIR}
            SUBBUILD_DIR ${thirdParty}/CMakeArtifacts/${name}-sub-${version}
            BINARY_DIR ${thirdParty}/CMakeArtifacts/${name}-${version})
    endif ()
endmacro()

macro(CmDepFetch3rdParty_File name version url destination_name url_hash)
    if (CMDEP_3RD_PARTY_DIR)
        set(_CmDep_3rdPartyDir "${CMDEP_3RD_PARTY_DIR}")
    elseif (POINTS_3RD_PARTY_DIR)
        set(_CmDep_3rdPartyDir "${POINTS_3RD_PARTY_DIR}")
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

function(CmDepFetch3rdParty)
    if (NOT DEFINED CMDEP_3RD_PARTY_PACKAGES_FILE)
        message(FATAL_ERROR "CMDEP_3RD_PARTY_PACKAGES_FILE must be set before calling CmDepFetch3rdParty()")
    endif ()
    include(FetchContent)
    set(FETCHCONTENT_QUIET OFF)
    include(${CMDEP_3RD_PARTY_PACKAGES_FILE})
endfunction()
