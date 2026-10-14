function(_CmDepProjectPrefix out_var)
    if (DEFINED CMDEP_PROJECT AND NOT CMDEP_PROJECT STREQUAL "")
        set(_p "${CMDEP_PROJECT}")
    else ()
        set(_p "${PROJECT_NAME}")
    endif ()
    if (_p STREQUAL "" AND NOT CMAKE_SCRIPT_MODE_FILE)
        message(WARNING "cmake-dep: CMDEP_PROJECT and PROJECT_NAME are both empty; "
                        "override / USE_SYSTEM knobs will have no prefix.")
    endif ()
    string(TOUPPER "${_p}" _p)
    string(MAKE_C_IDENTIFIER "${_p}" _p)
    set(${out_var} "${_p}" PARENT_SCOPE)
endfunction()

# Where fetched sources live. Defaults to a per-user cache shared by every
# project, checkout and worktree:
#   CMDEP_DIR (CMake variable)  >  $ENV{CMDEP_DIR}  >  $XDG_CACHE_HOME/cmake-dep
#   > ~/.cache/cmake-dep  (%LOCALAPPDATA%/cmake-dep on Windows)
# A relative CMDEP_DIR is resolved against the project root.
function(CmDepCacheDir out_var)
    if (DEFINED CMDEP_DIR AND NOT CMDEP_DIR STREQUAL "")
        set(_dir "${CMDEP_DIR}")
    elseif (DEFINED ENV{CMDEP_DIR} AND NOT "$ENV{CMDEP_DIR}" STREQUAL "")
        set(_dir "$ENV{CMDEP_DIR}")
    elseif (DEFINED ENV{XDG_CACHE_HOME} AND NOT "$ENV{XDG_CACHE_HOME}" STREQUAL "")
        set(_dir "$ENV{XDG_CACHE_HOME}/cmake-dep")
    elseif (WIN32 AND DEFINED ENV{LOCALAPPDATA})
        set(_dir "$ENV{LOCALAPPDATA}/cmake-dep")
    elseif (DEFINED ENV{HOME} AND NOT "$ENV{HOME}" STREQUAL "")
        set(_dir "$ENV{HOME}/.cache/cmake-dep")
    else ()
        message(FATAL_ERROR "cmake-dep: cannot determine a cache directory (no HOME); set CMDEP_DIR")
    endif ()

    if (CMDEP_PROJECT_ROOT)
        set(_base "${CMDEP_PROJECT_ROOT}")
    elseif (PROJECT_SOURCE_DIR)
        set(_base "${PROJECT_SOURCE_DIR}")
    else ()
        set(_base "${CMAKE_CURRENT_SOURCE_DIR}")
    endif ()
    file(TO_CMAKE_PATH "${_dir}" _dir)
    get_filename_component(_dir "${_dir}" ABSOLUTE BASE_DIR "${_base}")
    set(${out_var} "${_dir}" PARENT_SCOPE)
endfunction()

# The single fetch path. Downloads <url> (verified against <url_hash>, ALGO=HEX)
# into <cache>/<name>-<version>-<hash12>/ and returns that directory in out_var.
#
# KIND ARCHIVE extracts the download (stripping a single top-level directory);
# KIND FILE stores it as <FILE_NAME>.
#
# Completeness is tracked by a stamp file (.cmake-dep-complete) inside the
# directory. The directory is assembled in a temp dir, the stamp written last,
# and only then renamed into place -- so a directory with a stamp is always
# complete, and one without is a leftover from an interrupted fetch that gets
# removed and re-fetched. All mutation happens under a per-entry file(LOCK), so
# concurrent configures (other checkouts, worktrees, parallel CI jobs) wait for
# each other instead of racing. There is no retry loop: if the stamp is not
# present after the rename, the fetch fails hard.
#
# The hash is part of the directory name so two projects pinning the same
# version to different archives (or a -D URL/hash override) never share or
# clobber each other's tree.
function(_CmDepPopulate out_var name version url url_hash)
    cmake_parse_arguments(PARSE_ARGV 5 _P "" "KIND;FILE_NAME" "")
    if (NOT _P_KIND)
        set(_P_KIND ARCHIVE)
    endif ()

    string(REGEX MATCH "^([^=]+)=([0-9A-Fa-f]+)$" _m "${url_hash}")
    if (NOT _m)
        message(FATAL_ERROR "cmake-dep: hash for '${name}' must be ALGO=HEX, got '${url_hash}'")
    endif ()
    string(TOUPPER "${CMAKE_MATCH_1}" _algo)
    string(TOLOWER "${CMAKE_MATCH_2}" _hex)
    set(_algos MD5 SHA1 SHA224 SHA256 SHA384 SHA512 SHA3_224 SHA3_256 SHA3_384 SHA3_512)
    list(FIND _algos "${_algo}" _algo_idx)  # not IN_LIST: bare `cmake -P` lacks CMP0057
    if (_algo_idx EQUAL -1)
        message(FATAL_ERROR "cmake-dep: unsupported hash algorithm '${_algo}' for '${name}'")
    endif ()
    string(SUBSTRING "${_hex}" 0 12 _short)

    CmDepCacheDir(_root)
    set(_entry "${name}-${version}-${_short}")
    set(_dest "${_root}/${_entry}")
    set(_stamp "${_dest}/.cmake-dep-complete")
    set(${out_var} "${_dest}" PARENT_SCOPE)

    # Fast path, no lock: a stamped directory is complete and is never removed.
    if (EXISTS "${_stamp}")
        return()
    endif ()

    file(MAKE_DIRECTORY "${_root}/.locks" "${_root}/.tmp")
    set(_lock "${_root}/.locks/${_entry}.lock")
    file(LOCK "${_lock}" GUARD FUNCTION TIMEOUT 0 RESULT_VARIABLE _lock_res)
    if (NOT _lock_res EQUAL 0)
        message(STATUS "cmake-dep: ${_entry}: waiting for another process to finish fetching...")
        file(LOCK "${_lock}" GUARD FUNCTION)
    endif ()

    # Another process may have completed it while we waited.
    if (EXISTS "${_stamp}")
        file(LOCK "${_lock}" RELEASE)
        return()
    endif ()

    if (EXISTS "${_dest}")
        message(STATUS "cmake-dep: ${_entry}: incomplete (no stamp), removing and re-fetching")
        file(REMOVE_RECURSE "${_dest}")
    endif ()

    set(_tmp "${_root}/.tmp/${_entry}")
    file(REMOVE_RECURSE "${_tmp}")
    file(MAKE_DIRECTORY "${_tmp}")

    if (_P_KIND STREQUAL "FILE")
        set(_download "${_tmp}/content/${_P_FILE_NAME}")
    else ()
        string(REGEX REPLACE "[?#].*$" "" _url_path "${url}")
        string(REGEX MATCH "[^/]+$" _archive_name "${_url_path}")
        if (NOT _archive_name)
            set(_archive_name "archive")
        endif ()
        set(_download "${_tmp}/${_archive_name}")
    endif ()

    # The hash is checked by hand rather than with EXPECTED_HASH, which raises
    # its own error on mismatch and would skip the temp-dir cleanup.
    message(STATUS "cmake-dep: ${_entry}: downloading ${url}")
    file(DOWNLOAD "${url}" "${_download}" STATUS _status)
    list(GET _status 0 _code)
    if (NOT _code EQUAL 0)
        list(GET _status 1 _msg)
        file(REMOVE_RECURSE "${_tmp}")
        message(FATAL_ERROR "cmake-dep: download failed for ${name} (${url}): ${_msg}")
    endif ()
    file(${_algo} "${_download}" _actual)
    if (NOT _actual STREQUAL _hex)
        file(REMOVE_RECURSE "${_tmp}")
        message(FATAL_ERROR "cmake-dep: ${_algo} mismatch for ${name} (${url})\n"
                            "  expected: ${_hex}\n  actual:   ${_actual}")
    endif ()

    if (_P_KIND STREQUAL "FILE")
        set(_content "${_tmp}/content")
    else ()
        set(_extract "${_tmp}/extract")
        file(MAKE_DIRECTORY "${_extract}")
        file(ARCHIVE_EXTRACT INPUT "${_download}" DESTINATION "${_extract}")
        file(GLOB _children LIST_DIRECTORIES true "${_extract}/*" "${_extract}/.*")
        list(LENGTH _children _n)
        set(_content "${_extract}")
        if (_n EQUAL 1)
            list(GET _children 0 _only)
            if (IS_DIRECTORY "${_only}")
                set(_content "${_only}")
            endif ()
        endif ()
    endif ()

    # Stamp last, then publish atomically (same filesystem: .tmp is under _root).
    file(WRITE "${_content}/.cmake-dep-complete"
        "name=${name}\nversion=${version}\nurl=${url}\nhash=${url_hash}\n")
    file(RENAME "${_content}" "${_dest}")
    file(REMOVE_RECURSE "${_tmp}")

    if (NOT EXISTS "${_stamp}")
        message(FATAL_ERROR "cmake-dep: ${_entry}: stamp file missing after fetch (${_stamp}); "
                            "refusing to continue to avoid a re-fetch loop")
    endif ()
    message(STATUS "cmake-dep: ${_entry}: done")
    file(LOCK "${_lock}" RELEASE)
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
    set(_cmdep_use_system "${${_cmdep_var_sys}}")

    if (_cmdep_use_system)
        set(_cmdep_src "")
        if (CMAKE_SCRIPT_MODE_FILE)
            message(STATUS "cmake-dep: ${name}: USE_SYSTEM set, skipping download")
        endif ()
    else ()
        _CmDepPopulate(_cmdep_src ${name} "${_cmdep_eff_version}"
            "${${_cmdep_var_url}}" "${_cmdep_algo}=${${_cmdep_var_hash}}")
    endif ()

    set(${name}_SOURCE_DIR "${_cmdep_src}")
    set(${name}_VERSION "${_cmdep_eff_version}")
    set(${name}_USE_SYSTEM "${_cmdep_use_system}")
    set(${name}_SOURCE_DIR "${_cmdep_src}" PARENT_SCOPE)
    set(${name}_VERSION "${_cmdep_eff_version}" PARENT_SCOPE)
    set(${name}_USE_SYSTEM "${_cmdep_use_system}" PARENT_SCOPE)
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
    _CmDepPopulate(_cmdep_src ${name} "${version}" "${url}" "${url_hash}"
        KIND FILE FILE_NAME "${destination_name}")
    set(${name}_SOURCE_DIR "${_cmdep_src}")
    set(${name}_VERSION "${version}")
    set(${name}_SOURCE_DIR "${_cmdep_src}" PARENT_SCOPE)
    set(${name}_VERSION "${version}" PARENT_SCOPE)
endmacro()

function(CmDepFetch)
    if (NOT DEFINED CMDEP_PACKAGES_FILE)
        message(FATAL_ERROR "CMDEP_PACKAGES_FILE must be set before calling CmDepFetch()")
    endif ()
    include(${CMDEP_PACKAGES_FILE})
endfunction()
