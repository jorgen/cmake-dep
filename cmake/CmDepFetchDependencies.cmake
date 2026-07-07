# Standalone dependency fetcher.
#
# Can be used directly as a script:
#   cmake -DCMDEP_PACKAGES_FILE=CMake/3rdPartyPackages.cmake -P 3rdparty/cmake-dep/cmake/CmDepFetchDependencies.cmake
#
# Optional variables (pass with -D):
#   CMDEP_PACKAGES_FILE  - path to the packages file (required in script mode)
#   CMDEP_PROJECT_ROOT   - project root directory (defaults to cwd)
#   CMDEP_DIR            - override 3rdparty directory
#   CMDEP_PROJECT        - knob prefix (enables -D<PREFIX>_<DEP>_URL/_SHA256/_VERSION
#                          overrides and <PREFIX>_USE_SYSTEM_<DEP> skips; without it
#                          the packages file's positional defaults are used)
#
# Or include() it and call the function directly:
#   include(CmDepFetchDependencies)
#   CmDepFetchSetup(project_root packages_file)

function(CmDepFetchSetup project_root packages_file)
    # Determine the 3rdparty directory
    if(CMDEP_DIR)
        set(_3rdparty_dir "${CMDEP_DIR}")
    else()
        set(_3rdparty_dir "${project_root}/3rdparty")
    endif()
    get_filename_component(_3rdparty_dir "${_3rdparty_dir}" ABSOLUTE)
    file(MAKE_DIRECTORY "${_3rdparty_dir}")

    message(STATUS "3rdparty directory: ${_3rdparty_dir}")

    if(DEFINED CMDEP_PROJECT AND NOT CMDEP_PROJECT STREQUAL "")
        string(TOUPPER "${CMDEP_PROJECT}" _cmdep_prefix)
    elseif(DEFINED PROJECT_NAME AND NOT PROJECT_NAME STREQUAL "")
        string(TOUPPER "${PROJECT_NAME}" _cmdep_prefix)
    else()
        set(_cmdep_prefix "")
    endif()
    string(MAKE_C_IDENTIFIER "${_cmdep_prefix}" _cmdep_prefix)

    macro(CmDepFetchPackage name version url url_hash)
        string(TOUPPER "${name}" _dep)
        string(MAKE_C_IDENTIFIER "${_dep}" _dep)

        string(REGEX MATCH "^([^=]+)=(.*)$" _hash_m "${url_hash}")
        set(_algo "${CMAKE_MATCH_1}")
        set(_hex "${CMAKE_MATCH_2}")

        set(_eff_version "${version}")
        if(DEFINED ${_cmdep_prefix}_${_dep}_VERSION)
            set(_eff_version "${${_cmdep_prefix}_${_dep}_VERSION}")
        endif()
        set(_eff_url "${url}")
        if(DEFINED ${_cmdep_prefix}_${_dep}_URL)
            set(_eff_url "${${_cmdep_prefix}_${_dep}_URL}")
        endif()
        set(_eff_hex "${_hex}")
        if(DEFINED ${_cmdep_prefix}_${_dep}_${_algo})
            set(_eff_hex "${${_cmdep_prefix}_${_dep}_${_algo}}")
        endif()

        set(_target_dir "${_3rdparty_dir}/${name}-${_eff_version}")

        if(${_cmdep_prefix}_USE_SYSTEM_${_dep})
            message(STATUS "${name}: USE_SYSTEM set, skipping download")
        elseif(EXISTS "${_target_dir}")
            message(STATUS "${name}-${_eff_version}: already exists, skipping")
        else()
            message(STATUS "${name}-${_eff_version}: downloading...")

            set(_tmp_dir "${_3rdparty_dir}/.fetch_tmp_${name}")
            file(REMOVE_RECURSE "${_tmp_dir}")
            file(MAKE_DIRECTORY "${_tmp_dir}")

            # Determine archive filename from URL
            string(REGEX MATCH "[^/]+$" _archive_name "${_eff_url}")
            set(_archive_path "${_tmp_dir}/${_archive_name}")

            file(DOWNLOAD "${_eff_url}" "${_archive_path}"
                SHOW_PROGRESS
                EXPECTED_HASH "${_algo}=${_eff_hex}"
                STATUS _download_status
            )
            list(GET _download_status 0 _status_code)
            if(NOT _status_code EQUAL 0)
                list(GET _download_status 1 _error_msg)
                file(REMOVE_RECURSE "${_tmp_dir}")
                message(FATAL_ERROR "Download failed for ${name}: ${_error_msg}")
            endif()

            # Extract to temp location
            set(_extract_dir "${_tmp_dir}/extracted")
            file(MAKE_DIRECTORY "${_extract_dir}")
            file(ARCHIVE_EXTRACT INPUT "${_archive_path}" DESTINATION "${_extract_dir}")

            # Find the single top-level directory in the extracted content
            file(GLOB _children "${_extract_dir}/*")
            list(LENGTH _children _num_children)
            if(_num_children EQUAL 1)
                list(GET _children 0 _single_child)
                if(IS_DIRECTORY "${_single_child}")
                    file(RENAME "${_single_child}" "${_target_dir}")
                else()
                    file(RENAME "${_extract_dir}" "${_target_dir}")
                endif()
            else()
                file(RENAME "${_extract_dir}" "${_target_dir}")
            endif()

            file(REMOVE_RECURSE "${_tmp_dir}")
            message(STATUS "${name}-${_eff_version}: done")
        endif()
    endmacro()

    include("${packages_file}")

    message(STATUS "All dependencies fetched to: ${_3rdparty_dir}")
endfunction()

# Auto-invoke when run as: cmake -DCMDEP_PACKAGES_FILE=... -P CmDepFetchDependencies.cmake
if(DEFINED CMDEP_PACKAGES_FILE AND CMAKE_SCRIPT_MODE_FILE)
    if(NOT CMDEP_PROJECT_ROOT)
        set(CMDEP_PROJECT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}")
    endif()
    get_filename_component(CMDEP_PROJECT_ROOT "${CMDEP_PROJECT_ROOT}" ABSOLUTE)
    get_filename_component(CMDEP_PACKAGES_FILE "${CMDEP_PACKAGES_FILE}" ABSOLUTE)

    if(NOT EXISTS "${CMDEP_PACKAGES_FILE}")
        message(FATAL_ERROR "Packages file not found: ${CMDEP_PACKAGES_FILE}")
    endif()

    CmDepFetchSetup("${CMDEP_PROJECT_ROOT}" "${CMDEP_PACKAGES_FILE}")
endif()
