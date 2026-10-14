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

# ---------------------------------------------------------------------------
# Settings
#
# Machine-level settings (where the cache lives, which mirrors to use) are read
# with this precedence, first hit wins:
#   1. CMake variable   (-DCMDEP_MIRRORS=... or set() before the fetch)
#   2. environment      ($ENV{CMDEP_MIRRORS})
#   3. user config file ($CMDEP_CONFIG, else $XDG_CONFIG_HOME/cmake-dep/config.cmake,
#                        else ~/.config/cmake-dep/config.cmake,
#                        %APPDATA%/cmake-dep/config.cmake on Windows)
#   4. built-in default
# An empty value at any level means "use the default".
# ---------------------------------------------------------------------------
function(_CmDepConfigFile out_var)
    if (DEFINED ENV{CMDEP_CONFIG} AND NOT "$ENV{CMDEP_CONFIG}" STREQUAL "")
        set(_f "$ENV{CMDEP_CONFIG}")
    elseif (DEFINED ENV{XDG_CONFIG_HOME} AND NOT "$ENV{XDG_CONFIG_HOME}" STREQUAL "")
        set(_f "$ENV{XDG_CONFIG_HOME}/cmake-dep/config.cmake")
    elseif (WIN32 AND DEFINED ENV{APPDATA})
        set(_f "$ENV{APPDATA}/cmake-dep/config.cmake")
    elseif (DEFINED ENV{HOME} AND NOT "$ENV{HOME}" STREQUAL "")
        set(_f "$ENV{HOME}/.config/cmake-dep/config.cmake")
    else ()
        set(_f "")
    endif ()
    if (_f)
        file(TO_CMAKE_PATH "${_f}" _f)
    endif ()
    set(${out_var} "${_f}" PARENT_SCOPE)
endfunction()

# Loads the user config file once per CMake run. Values are captured into
# global properties so they rank below CMake/env variables (see _CmDepSetting).
function(_CmDepLoadConfig)
    get_property(_loaded GLOBAL PROPERTY CMDEP_CONFIG_LOADED)
    if (_loaded)
        return()
    endif ()
    set_property(GLOBAL PROPERTY CMDEP_CONFIG_LOADED TRUE)
    _CmDepConfigFile(_file)
    if (NOT _file OR NOT EXISTS "${_file}")
        return()
    endif ()
    set(_keys CMDEP_DIR CMDEP_MIRRORS CMDEP_MIRROR_PUSH CMDEP_KEEP_ARCHIVES
              CMDEP_MIRROR_TIMEOUT CMDEP_MIRROR_HTTPHEADER
              CMDEP_BINARIES CMDEP_BINARY_MIRRORS CMDEP_BINARY_PUSH CMDEP_BINARY_PLATFORM
              CMDEP_BINARY_JOBS)
    # Sentinel-fill so we only capture what the file itself sets, not values
    # inherited from the calling scope.
    foreach (_k IN LISTS _keys)
        set(${_k} "__cmdep_unset__")
    endforeach ()
    include("${_file}")
    foreach (_k IN LISTS _keys)
        if (NOT "${${_k}}" STREQUAL "__cmdep_unset__")
            set_property(GLOBAL PROPERTY CMDEP_CONFIG_${_k} "${${_k}}")
        endif ()
    endforeach ()
endfunction()

function(_CmDepSetting out_var name default)
    _CmDepLoadConfig()
    get_property(_has_cfg GLOBAL PROPERTY CMDEP_CONFIG_${name} SET)
    if (DEFINED ${name})
        set(_v "${${name}}")
    elseif (DEFINED ENV{${name}})
        set(_v "$ENV{${name}}")
    elseif (_has_cfg)
        get_property(_v GLOBAL PROPERTY CMDEP_CONFIG_${name})
    else ()
        set(_v "")
    endif ()
    if ("${_v}" STREQUAL "")
        set(_v "${default}")
    endif ()
    set(${out_var} "${_v}" PARENT_SCOPE)
endfunction()

# Where fetched sources live. Defaults to a per-user cache shared by every
# project, checkout and worktree:
#   CMDEP_DIR (variable > env > config file)  >  $XDG_CACHE_HOME/cmake-dep
#   > ~/.cache/cmake-dep  (%LOCALAPPDATA%/cmake-dep on Windows)
# A relative CMDEP_DIR is resolved against the project root.
function(CmDepCacheDir out_var)
    _CmDepSetting(_dir CMDEP_DIR "")
    if (NOT _dir STREQUAL "")
        # explicit
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

# ---------------------------------------------------------------------------
# Mirrors
#
# A mirror is content-addressed: the archive with hash ALGO=HEX lives at
# <mirror>/<algo>/<hex> (algo lowercased, e.g. sha256/27e55cf7...). Because
# every blob is hash-verified locally, a mirror need not be trusted.
#
# CMDEP_MIRRORS is an ordered list (';' or ',' separated) of mirror bases,
# file:// URLs, plain directory paths, http(s):// URLs, and the keyword
# `direct` (the package's own upstream URL). Default: `direct`. Leaving
# `direct` out makes the mirrors the only allowed sources.
# ---------------------------------------------------------------------------
function(_CmDepMirrorList out_var)
    _CmDepSetting(_m CMDEP_MIRRORS "direct")
    string(REPLACE "," ";" _m "${_m}")
    set(_out "")
    foreach (_e IN LISTS _m)
        string(STRIP "${_e}" _e)
        if (_e STREQUAL "")
            continue()
        endif ()
        if (NOT _e STREQUAL "direct")
            string(REGEX REPLACE "/+$" "" _e "${_e}")
        endif ()
        list(APPEND _out "${_e}")
    endforeach ()
    set(${out_var} "${_out}" PARENT_SCOPE)
endfunction()

# Sets out_var to the local directory for a file:// URL or plain path, or ""
# for a network URL.
function(_CmDepLocalPath out_var location)
    if (location MATCHES "^file://(.*)$")
        set(_p "${CMAKE_MATCH_1}")
        if (_p MATCHES "^/([A-Za-z]:.*)$")  # file:///C:/x -> C:/x
            set(_p "${CMAKE_MATCH_1}")
        endif ()
    elseif (location MATCHES "^[A-Za-z][A-Za-z0-9+.-]+://")
        set(_p "")
    else ()
        set(_p "${location}")
    endif ()
    set(${out_var} "${_p}" PARENT_SCOPE)
endfunction()

# Copy (or, with MOVE, rename -- same filesystem only) src to dest so that dest
# appears atomically: readers of a shared mirror never see a partial file.
# Best effort: sets out_ok instead of failing, since pushing to a mirror must
# never break a build.
function(_CmDepPublishBlob out_ok src dest)
    cmake_parse_arguments(PARSE_ARGV 3 _P "MOVE" "" "")
    get_filename_component(_dir "${dest}" DIRECTORY)
    execute_process(COMMAND ${CMAKE_COMMAND} -E make_directory "${_dir}"
        RESULT_VARIABLE _r OUTPUT_QUIET ERROR_QUIET)
    if (NOT _r EQUAL 0)
        set(${out_ok} FALSE PARENT_SCOPE)
        return()
    endif ()
    if (_P_MOVE)
        execute_process(COMMAND ${CMAKE_COMMAND} -E rename "${src}" "${dest}"
            RESULT_VARIABLE _r OUTPUT_QUIET ERROR_QUIET)
    else ()
        string(RANDOM LENGTH 10 _rand)
        set(_part "${dest}.part-${_rand}")
        execute_process(COMMAND ${CMAKE_COMMAND} -E copy "${src}" "${_part}"
            RESULT_VARIABLE _r OUTPUT_QUIET ERROR_QUIET)
        if (_r EQUAL 0)
            execute_process(COMMAND ${CMAKE_COMMAND} -E rename "${_part}" "${dest}"
                RESULT_VARIABLE _r OUTPUT_QUIET ERROR_QUIET)
        endif ()
        if (NOT _r EQUAL 0)
            file(REMOVE "${_part}")
        endif ()
    endif ()
    if (_r EQUAL 0)
        set(${out_ok} TRUE PARENT_SCOPE)
    else ()
        set(${out_ok} FALSE PARENT_SCOPE)
    endif ()
endfunction()

# Tries one source. out_status is one of:
#   OK    dest holds the verified blob
#   MISS  the source does not have it (missing file, HTTP error such as 404)
#   DEAD  the source could not be reached (connection/timeout error)
#   BAD   the source returned content with the wrong hash
# algo NONE skips hash verification (used for small metadata files).
function(_CmDepTryFetch out_status out_msg location dest algo hex is_mirror)
    file(REMOVE "${dest}")
    _CmDepLocalPath(_local "${location}")
    if (_local)
        if (NOT EXISTS "${_local}")
            set(${out_status} MISS PARENT_SCOPE)
            set(${out_msg} "not present" PARENT_SCOPE)
            return()
        endif ()
        execute_process(COMMAND ${CMAKE_COMMAND} -E copy "${_local}" "${dest}"
            RESULT_VARIABLE _r OUTPUT_QUIET ERROR_VARIABLE _err)
        if (NOT _r EQUAL 0)
            set(${out_status} DEAD PARENT_SCOPE)
            set(${out_msg} "copy failed: ${_err}" PARENT_SCOPE)
            return()
        endif ()
    else ()
        set(_opts STATUS _s)
        if (is_mirror)
            _CmDepSetting(_timeout CMDEP_MIRROR_TIMEOUT 10)
            list(APPEND _opts INACTIVITY_TIMEOUT ${_timeout} NETRC OPTIONAL)
            # Mirror credentials only ever go to mirrors, never upstream.
            _CmDepSetting(_hdr CMDEP_MIRROR_HTTPHEADER "")
            if (_hdr)
                list(APPEND _opts HTTPHEADER "${_hdr}")
            endif ()
        endif ()
        file(DOWNLOAD "${location}" "${dest}" ${_opts})
        list(GET _s 0 _code)
        if (NOT _code EQUAL 0)
            list(GET _s 1 _err)
            file(REMOVE "${dest}")
            set(${out_msg} "${_err}" PARENT_SCOPE)
            if (_code EQUAL 22)  # CURLE_HTTP_RETURNED_ERROR (404, 403, ...)
                set(${out_status} MISS PARENT_SCOPE)
            else ()
                set(${out_status} DEAD PARENT_SCOPE)
            endif ()
            return()
        endif ()
    endif ()
    if (algo STREQUAL "NONE")
        set(${out_status} OK PARENT_SCOPE)
        set(${out_msg} "" PARENT_SCOPE)
        return()
    endif ()
    file(${algo} "${dest}" _actual)
    if (NOT _actual STREQUAL hex)
        file(REMOVE "${dest}")
        set(${out_status} BAD PARENT_SCOPE)
        set(${out_msg} "${algo} mismatch (expected ${hex}, got ${_actual})" PARENT_SCOPE)
        return()
    endif ()
    set(${out_status} OK PARENT_SCOPE)
    set(${out_msg} "" PARENT_SCOPE)
endfunction()

# Obtains a verified copy of blob <algo>/<hex>. Looks in the local archive
# store first, then each CMDEP_MIRRORS entry in order (`direct` = <url>).
# Sets out_path to the verified file -- the store copy, or <work_dir>/download
# -- and out_source to "store", the mirror base, or "direct". Fails with the
# list of every source tried if none has it.
function(_CmDepAcquire out_path out_source name url algo hex work_dir)
    CmDepCacheDir(_root)
    string(TOLOWER "${algo}" _adir)
    set(_store "${_root}/archives/${_adir}/${hex}")
    if (EXISTS "${_store}")
        file(${algo} "${_store}" _actual)
        if (_actual STREQUAL hex)
            set(${out_path} "${_store}" PARENT_SCOPE)
            set(${out_source} "store" PARENT_SCOPE)
            return()
        endif ()
        message(STATUS "cmake-dep: ${name}: archive store copy is corrupt, removing it")
        file(REMOVE "${_store}")
    endif ()

    _CmDepMirrorList(_sources)
    set(_dl "${work_dir}/download")
    set(_errors "")
    set(_has_direct FALSE)
    foreach (_src IN LISTS _sources)
        if (_src STREQUAL "direct")
            set(_has_direct TRUE)
            message(STATUS "cmake-dep: ${name}: downloading ${url}")
            _CmDepTryFetch(_st _msg "${url}" "${_dl}" ${algo} ${hex} FALSE)
        else ()
            get_property(_dead GLOBAL PROPERTY CMDEP_DEAD_MIRRORS)
            list(FIND _dead "${_src}" _i)
            if (NOT _i EQUAL -1)
                list(APPEND _errors "  ${_src}: skipped (unreachable earlier in this run)")
                continue()
            endif ()
            _CmDepTryFetch(_st _msg "${_src}/${_adir}/${hex}" "${_dl}" ${algo} ${hex} TRUE)
            if (_st STREQUAL "OK")
                message(STATUS "cmake-dep: ${name}: fetched from mirror ${_src}")
            elseif (_st STREQUAL "MISS")
                message(VERBOSE "cmake-dep: ${name}: not on mirror ${_src}")
            elseif (_st STREQUAL "DEAD")
                set_property(GLOBAL APPEND PROPERTY CMDEP_DEAD_MIRRORS "${_src}")
                message(STATUS "cmake-dep: mirror ${_src} unreachable (${_msg}); "
                               "skipping it for the rest of this run")
            elseif (_st STREQUAL "BAD")
                message(STATUS "cmake-dep: ${name}: mirror ${_src} served a corrupt copy (${_msg})")
            endif ()
        endif ()
        if (_st STREQUAL "OK")
            set(${out_path} "${_dl}" PARENT_SCOPE)
            set(${out_source} "${_src}" PARENT_SCOPE)
            return()
        endif ()
        list(APPEND _errors "  ${_src}: ${_msg}")
    endforeach ()

    file(REMOVE_RECURSE "${work_dir}")  # callers pass a dedicated work dir
    string(REPLACE ";" "\n" _errors "${_errors}")
    set(_hint "")
    if (NOT _has_direct)
        set(_hint "\n  ('direct' is not in CMDEP_MIRRORS, so the upstream URL ${url} was not tried)")
    endif ()
    message(FATAL_ERROR "cmake-dep: could not fetch ${name} (${algo}=${hex}) from any source:\n"
                        "${_errors}${_hint}")
endfunction()

# Uploads <file> to <target>/<relpath>: a directory/file:// target gets an
# atomic copy (skipped if already present), an http(s) target gets an HTTP PUT.
# Never fatal -- a failed push is reported and the build continues. Sets
# out_ok to TRUE/FALSE.
function(_CmDepPushFile out_ok target relpath file name)
    string(REGEX REPLACE "/+$" "" target "${target}")
    _CmDepLocalPath(_local "${target}")
    if (_local)
        set(_dest "${_local}/${relpath}")
        if (EXISTS "${_dest}")
            set(${out_ok} TRUE PARENT_SCOPE)
            return()
        endif ()
        _CmDepPublishBlob(_ok "${file}" "${_dest}")
    else ()
        _CmDepSetting(_timeout CMDEP_MIRROR_TIMEOUT 10)
        set(_opts STATUS _s INACTIVITY_TIMEOUT ${_timeout} NETRC OPTIONAL)
        _CmDepSetting(_hdr CMDEP_MIRROR_HTTPHEADER "")
        if (_hdr)
            list(APPEND _opts HTTPHEADER "${_hdr}")
        endif ()
        file(UPLOAD "${file}" "${target}/${relpath}" ${_opts})
        list(GET _s 0 _code)
        if (_code EQUAL 0)
            set(_ok TRUE)
        else ()
            set(_ok FALSE)
        endif ()
    endif ()
    if (NOT _ok)
        message(WARNING "cmake-dep: ${name}: could not push to mirror ${target}")
    endif ()
    set(${out_ok} ${_ok} PARENT_SCOPE)
endfunction()

# Pushes a verified source archive to <target>/<algo>/<hex>.
function(_CmDepPushTo target blob name algo hex)
    string(TOLOWER "${algo}" _adir)
    _CmDepPushFile(_ok "${target}" "${_adir}/${hex}" "${blob}" ${name})
    if (_ok)
        message(STATUS "cmake-dep: ${name}: pushed to mirror ${target}")
    endif ()
endfunction()

# Script-mode helper for CmDepMirror.cmake: make blob <algo>/<hex> present in
# CMDEP_MIRROR_OUT, fetching it through the normal store/mirror/direct chain.
function(_CmDepExportBlob name url algo hex)
    string(TOLOWER "${algo}" _adir)
    string(REGEX REPLACE "/+$" "" _out "${CMDEP_MIRROR_OUT}")
    _CmDepLocalPath(_local "${_out}")
    if (_local)
        set(_dest "${_local}/${_adir}/${hex}")
        if (EXISTS "${_dest}")
            file(${algo} "${_dest}" _actual)
            if (_actual STREQUAL hex)
                message(STATUS "cmake-dep: ${name}: already in ${_out}")
                return()
            endif ()
            message(STATUS "cmake-dep: ${name}: corrupt copy in ${_out}, replacing")
            file(REMOVE "${_dest}")
        endif ()
    endif ()

    CmDepCacheDir(_root)
    file(MAKE_DIRECTORY "${_root}/.locks" "${_root}/.tmp")
    set(_lock "${_root}/.locks/blob-${hex}.lock")
    file(LOCK "${_lock}" GUARD FUNCTION)
    set(_work "${_root}/.tmp/blob-${hex}")
    file(REMOVE_RECURSE "${_work}")
    file(MAKE_DIRECTORY "${_work}")

    _CmDepAcquire(_blob _source ${name} "${url}" ${algo} ${hex} "${_work}")
    _CmDepPushTo("${_out}" "${_blob}" ${name} ${algo} ${hex})
    _CmDepSetting(_keep CMDEP_KEEP_ARCHIVES ON)
    if (_keep AND NOT _source STREQUAL "store")
        _CmDepPublishBlob(_ok "${_blob}" "${_root}/archives/${_adir}/${hex}" MOVE)
    endif ()
    file(REMOVE_RECURSE "${_work}")
    file(LOCK "${_lock}" RELEASE)
endfunction()

# The single fetch path. Obtains the archive <url> (verified against
# <url_hash>, ALGO=HEX) and populates <cache>/<name>-<version>-<hash12>/,
# returning that directory in out_var.
#
# KIND ARCHIVE extracts the download (stripping a single top-level directory);
# KIND FILE stores it as <FILE_NAME>.
#
# Where the bytes come from (see _CmDepAcquire): the local archive store
# (<cache>/archives/<algo>/<hex>), then each CMDEP_MIRRORS entry, where
# `direct` is <url> itself. After a network fetch the archive is kept in the
# store (CMDEP_KEEP_ARCHIVES, default ON) and pushed to CMDEP_MIRROR_PUSH if
# set.
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

    # Mirror population mode (CmDepMirror.cmake): only collect the archive.
    if (CMDEP_MIRROR_OUT)
        _CmDepExportBlob(${name} "${url}" ${_algo} ${_hex})
        set(${out_var} "" PARENT_SCOPE)
        return()
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

    _CmDepAcquire(_blob _source ${name} "${url}" ${_algo} ${_hex} "${_tmp}")

    _CmDepSetting(_push CMDEP_MIRROR_PUSH "")
    string(REGEX REPLACE "/+$" "" _push "${_push}")
    if (_push AND NOT _source STREQUAL "store" AND NOT _source STREQUAL _push)
        _CmDepPushTo("${_push}" "${_blob}" ${name} ${_algo} ${_hex})
    endif ()

    _CmDepSetting(_keep CMDEP_KEEP_ARCHIVES ON)
    string(TOLOWER "${_algo}" _adir)
    set(_store "${_root}/archives/${_adir}/${_hex}")

    if (_P_KIND STREQUAL "FILE")
        set(_content "${_tmp}/content")
        file(MAKE_DIRECTORY "${_content}")
        if (_source STREQUAL "store")
            execute_process(COMMAND ${CMAKE_COMMAND} -E copy "${_blob}" "${_content}/${_P_FILE_NAME}"
                RESULT_VARIABLE _r)
            if (NOT _r EQUAL 0)
                message(FATAL_ERROR "cmake-dep: ${_entry}: could not copy ${_blob}")
            endif ()
        else ()
            if (_keep)
                _CmDepPublishBlob(_ok "${_blob}" "${_store}")
            endif ()
            file(RENAME "${_blob}" "${_content}/${_P_FILE_NAME}")
        endif ()
    else ()
        set(_extract "${_tmp}/extract")
        file(MAKE_DIRECTORY "${_extract}")
        file(ARCHIVE_EXTRACT INPUT "${_blob}" DESTINATION "${_extract}")
        if (_keep AND NOT _source STREQUAL "store")
            _CmDepPublishBlob(_ok "${_blob}" "${_store}" MOVE)
        endif ()
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
        "name=${name}\nversion=${version}\nurl=${url}\nhash=${url_hash}\nsource=${_source}\n")
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
    set(${name}_HASH "${_cmdep_algo}=${${_cmdep_var_hash}}")
    set(${name}_SOURCE_DIR "${_cmdep_src}" PARENT_SCOPE)
    set(${name}_VERSION "${_cmdep_eff_version}" PARENT_SCOPE)
    set(${name}_USE_SYSTEM "${_cmdep_use_system}" PARENT_SCOPE)
    set(${name}_HASH "${_cmdep_algo}=${${_cmdep_var_hash}}" PARENT_SCOPE)
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
