# Policies for cmake-dep's own code, so it behaves the same in a configure and
# in a bare `cmake -P` (include() keeps this from leaking into the includer).
cmake_policy(VERSION 3.18)

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
              CMDEP_BINARY_JOBS CMDEP_BINARY_SIGNING_KEY CMDEP_BINARY_TRUSTED_KEYS
              CMDEP_LOCK_FILE CMDEP_LOCKED CMDEP_TLS_CAINFO)
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

# Records that a cache entry (or archive) was used, for `cmdep gc`, by
# refreshing its mtime. Throttled to once a day so a configure normally writes
# nothing, and best effort so a read-only cache works.
function(_CmDepTouch path)
    file(TIMESTAMP "${path}" _t "%s" UTC)
    string(TIMESTAMP _now "%s" UTC)
    if (_t AND _now)
        math(EXPR _age "${_now} - ${_t}")
        if (_age LESS 86400)
            return()
        endif ()
    endif ()
    execute_process(COMMAND ${CMAKE_COMMAND} -E touch_nocreate "${path}"
        RESULT_VARIABLE _r OUTPUT_QUIET ERROR_QUIET)
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

# TLS options for a download/upload. Mirrors always verify certificates:
# binary packages have no pinned hash, and mirror requests may carry
# credentials. CMDEP_TLS_CAINFO (e.g. a corporate proxy's CA bundle) applies to
# every request; CMAKE_TLS_CAINFO / CMAKE_TLS_VERIFY keep working as usual.
function(_CmDepTlsOpts out_var is_mirror)
    set(_opts "")
    if (is_mirror)
        list(APPEND _opts TLS_VERIFY ON)
    endif ()
    _CmDepSetting(_ca CMDEP_TLS_CAINFO "")
    if (_ca)
        list(APPEND _opts TLS_CAINFO "${_ca}")
    endif ()
    set(${out_var} "${_opts}" PARENT_SCOPE)
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
        _CmDepTlsOpts(_opts ${is_mirror})
        list(APPEND _opts STATUS _s)
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

# ---------------------------------------------------------------------------
# Git sources
#
# A git dependency is pinned by commit. Its content is materialised as
#   git archive --format=tar --prefix=source/ <commit>
# which depends only on the commit, so it can be hash-addressed like any
# other archive (archive store, mirrors, write-back). In the fetch path its
# "URL" is git+<repo>#<commit>.
# ---------------------------------------------------------------------------

# Writes the archive of <commit> from <repo> to <dest>. Sets out_ok/out_msg.
# Git verifies the commit id itself, so the result is trustworthy whatever the
# transport.
function(_CmDepGitArchive out_ok out_msg dest repo commit)
    find_program(CMDEP_GIT_EXECUTABLE NAMES git)
    mark_as_advanced(CMDEP_GIT_EXECUTABLE)
    if (NOT CMDEP_GIT_EXECUTABLE)
        set(${out_ok} FALSE PARENT_SCOPE)
        set(${out_msg} "git not found" PARENT_SCOPE)
        return()
    endif ()
    get_filename_component(_d "${dest}" DIRECTORY)
    set(_w "${_d}/git-work")
    file(REMOVE_RECURSE "${_w}")
    file(MAKE_DIRECTORY "${_w}")
    set(_git ${CMAKE_COMMAND} -E env GIT_TERMINAL_PROMPT=0 "GIT_CEILING_DIRECTORIES=${_d}"
        "${CMDEP_GIT_EXECUTABLE}" -c core.autocrlf=false -c core.eol=lf -c tar.umask=0022)
    execute_process(COMMAND ${_git} init -q WORKING_DIRECTORY "${_w}" RESULT_VARIABLE _r OUTPUT_QUIET ERROR_QUIET)
    # Shallow fetch of exactly the commit; fall back to a full fetch for
    # servers that don't allow fetching an arbitrary commit.
    execute_process(COMMAND ${_git} fetch -q --depth 1 --no-tags "${repo}" "${commit}"
        WORKING_DIRECTORY "${_w}" RESULT_VARIABLE _r OUTPUT_QUIET ERROR_VARIABLE _e)
    if (NOT _r EQUAL 0)
        execute_process(COMMAND ${_git} fetch -q --no-tags "${repo}" "+refs/heads/*:refs/remotes/origin/*" "+refs/tags/*:refs/tags/*"
            WORKING_DIRECTORY "${_w}" RESULT_VARIABLE _r OUTPUT_QUIET ERROR_VARIABLE _e)
    endif ()
    if (_r EQUAL 0)
        execute_process(COMMAND ${_git} archive --format=tar --prefix=source/ -o "${dest}" "${commit}"
            WORKING_DIRECTORY "${_w}" RESULT_VARIABLE _r OUTPUT_QUIET ERROR_VARIABLE _e)
    endif ()
    file(REMOVE_RECURSE "${_w}")
    if (_r EQUAL 0)
        set(${out_ok} TRUE PARENT_SCOPE)
        set(${out_msg} "" PARENT_SCOPE)
    else ()
        file(REMOVE "${dest}")
        string(STRIP "${_e}" _e)
        set(${out_ok} FALSE PARENT_SCOPE)
        set(${out_msg} "git: ${_e}" PARENT_SCOPE)
    endif ()
endfunction()

# Returns the SHA256 of the archive of <commit> (see above), creating it in the
# archive store if needed. A small index (<cache>/git/<commit>.sha256) makes
# later lookups free. Used when a git dependency has no pinned hash, and by
# `cmdep add --git`.
function(_CmDepGitArchiveHash out_hex name repo commit)
    CmDepCacheDir(_root)
    set(_index "${_root}/git/${commit}.sha256")
    if (EXISTS "${_index}")
        file(READ "${_index}" _hex)
        string(STRIP "${_hex}" _hex)
        if (EXISTS "${_root}/archives/sha256/${_hex}")
            set(${out_hex} "${_hex}" PARENT_SCOPE)
            return()
        endif ()
    endif ()
    file(MAKE_DIRECTORY "${_root}/.locks" "${_root}/.tmp" "${_root}/git")
    set(_lock "${_root}/.locks/git-${commit}.lock")
    file(LOCK "${_lock}" GUARD FUNCTION)
    set(_work "${_root}/.tmp/git-${commit}")
    file(REMOVE_RECURSE "${_work}")
    file(MAKE_DIRECTORY "${_work}")
    message(STATUS "cmake-dep: ${name}: fetching ${repo} at ${commit}")
    _CmDepGitArchive(_ok _msg "${_work}/archive.tar" "${repo}" "${commit}")
    if (NOT _ok)
        file(REMOVE_RECURSE "${_work}")
        message(FATAL_ERROR "cmake-dep: ${name}: could not fetch ${repo} at ${commit}: ${_msg}")
    endif ()
    file(SHA256 "${_work}/archive.tar" _hex)
    _CmDepPublishBlob(_ok "${_work}/archive.tar" "${_root}/archives/sha256/${_hex}" MOVE)
    file(WRITE "${_index}.tmp" "${_hex}\n")
    file(RENAME "${_index}.tmp" "${_index}")
    file(REMOVE_RECURSE "${_work}")
    file(LOCK "${_lock}" RELEASE)
    set(${out_hex} "${_hex}" PARENT_SCOPE)
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
            _CmDepTouch("${_store}")
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
        if (_src STREQUAL "direct" AND url MATCHES "^git\\+(.+)#([0-9a-fA-F]+)$")
            set(_has_direct TRUE)
            set(_repo "${CMAKE_MATCH_1}")
            set(_commit "${CMAKE_MATCH_2}")
            message(STATUS "cmake-dep: ${name}: fetching ${_repo} at ${_commit}")
            _CmDepGitArchive(_ok _msg "${_dl}" "${_repo}" "${_commit}")
            if (_ok)
                file(${algo} "${_dl}" _actual)
                if (_actual STREQUAL hex)
                    set(_st OK)
                else ()
                    file(REMOVE "${_dl}")
                    set(_st BAD)
                    set(_msg "archive of ${_commit} has ${algo} ${_actual}, expected ${hex} (a different "
                             "git version can produce a different archive; re-pin with `cmdep add --git`)")
                endif ()
            else ()
                set(_st DEAD)
            endif ()
        elseif (_src STREQUAL "direct")
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
        _CmDepTlsOpts(_opts TRUE)
        list(APPEND _opts STATUS _s INACTIVITY_TIMEOUT ${_timeout} NETRC OPTIONAL)
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

    # Fast path, no lock: a stamped directory is complete and is only removed
    # by `cmdep gc` once unused for a while.
    if (EXISTS "${_stamp}")
        _CmDepTouch("${_stamp}")
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

# Applies <patches> (in order) to a copy of the fetched tree <base>, giving a
# separate cache entry <base>-p<hash8>, keyed by the patches' content. The
# shared, unpatched entry stays untouched. Patches are unified diffs applied
# with -p1 (git-style a/ b/ prefixes), using `git apply`, or `patch` if git is
# not available.
function(_CmDepPatch out_var name base)
    set(_patches ${ARGN})
    set(_ids "")
    foreach (_p IN LISTS _patches)
        if (NOT EXISTS "${_p}")
            message(FATAL_ERROR "cmake-dep: ${name}: patch not found: ${_p}")
        endif ()
        file(SHA256 "${_p}" _ph)
        string(APPEND _ids "${_ph}\n")
    endforeach ()
    string(SHA256 _pkey "${_ids}")
    string(SUBSTRING "${_pkey}" 0 8 _pshort)
    set(_dest "${base}-p${_pshort}")
    get_filename_component(_root "${base}" DIRECTORY)
    get_filename_component(_entry "${_dest}" NAME)
    set(_stamp "${_dest}/.cmake-dep-complete")
    set(${out_var} "${_dest}" PARENT_SCOPE)
    if (EXISTS "${_stamp}")
        _CmDepTouch("${_stamp}")
        return()
    endif ()

    file(MAKE_DIRECTORY "${_root}/.locks" "${_root}/.tmp")
    set(_lock "${_root}/.locks/${_entry}.lock")
    file(LOCK "${_lock}" GUARD FUNCTION)
    if (EXISTS "${_stamp}")
        file(LOCK "${_lock}" RELEASE)
        return()
    endif ()
    file(REMOVE_RECURSE "${_dest}")
    set(_tmp "${_root}/.tmp/${_entry}")
    file(REMOVE_RECURSE "${_tmp}")
    file(MAKE_DIRECTORY "${_tmp}")
    file(COPY "${base}/" DESTINATION "${_tmp}/tree")
    file(REMOVE "${_tmp}/tree/.cmake-dep-complete")

    find_program(CMDEP_GIT_EXECUTABLE NAMES git)
    find_program(CMDEP_PATCH_EXECUTABLE NAMES patch)
    mark_as_advanced(CMDEP_GIT_EXECUTABLE CMDEP_PATCH_EXECUTABLE)
    set(_applied "")
    foreach (_p IN LISTS _patches)
        get_filename_component(_pn "${_p}" NAME)
        if (CMDEP_GIT_EXECUTABLE)
            # GIT_CEILING_DIRECTORIES stops git from discovering an enclosing
            # repository (e.g. CMDEP_DIR=3rdparty inside the project), which
            # would make it apply paths relative to that repository.
            execute_process(
                COMMAND ${CMAKE_COMMAND} -E env "GIT_CEILING_DIRECTORIES=${_tmp}"
                        "${CMDEP_GIT_EXECUTABLE}" apply --whitespace=nowarn -p1 "${_p}"
                WORKING_DIRECTORY "${_tmp}/tree"
                RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
        elseif (CMDEP_PATCH_EXECUTABLE)
            execute_process(
                COMMAND "${CMDEP_PATCH_EXECUTABLE}" -p1 --batch --forward -i "${_p}"
                WORKING_DIRECTORY "${_tmp}/tree"
                RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
        else ()
            file(REMOVE_RECURSE "${_tmp}")
            message(FATAL_ERROR "cmake-dep: ${name}: PATCHES need git or patch on PATH")
        endif ()
        if (NOT _r EQUAL 0)
            file(REMOVE_RECURSE "${_tmp}")
            message(FATAL_ERROR "cmake-dep: ${name}: patch ${_pn} does not apply:\n${_o}${_e}")
        endif ()
        file(SHA256 "${_p}" _ph)
        string(APPEND _applied "patch=${_pn} ${_ph}\n")
    endforeach ()

    file(WRITE "${_tmp}/tree/.cmake-dep-complete" "patched_from=${base}\n${_applied}")
    file(RENAME "${_tmp}/tree" "${_dest}")
    file(REMOVE_RECURSE "${_tmp}")
    if (NOT EXISTS "${_stamp}")
        message(FATAL_ERROR "cmake-dep: ${_entry}: stamp file missing after patching")
    endif ()
    list(LENGTH _patches _np)
    message(STATUS "cmake-dep: ${_entry}: applied ${_np} patch(es)")
    file(LOCK "${_lock}" RELEASE)
endfunction()

# ---------------------------------------------------------------------------
# Package registry: one copy of each package per CMake run
#
# The first declaration of a name wins -- normally the root project's, since
# its CmDepFetch() runs before any dependency is add_subdirectory()'d, or the
# lockfile's choice (see CmDepLock.cmake). A dependency that declares the same
# package again gets the registered copy, so the whole build agrees on one
# version (C++ cannot link two).
# ---------------------------------------------------------------------------
function(_CmDepRegistryGet name out_found)
    get_property(_found GLOBAL PROPERTY CMDEP_REG_${name}_HASH SET)
    set(${out_found} ${_found} PARENT_SCOPE)
    if (_found)
        foreach (_f SOURCE_DIR VERSION HASH USE_SYSTEM BY)
            get_property(_v GLOBAL PROPERTY CMDEP_REG_${name}_${_f})
            set(_cmdep_reg_${_f} "${_v}" PARENT_SCOPE)
        endforeach ()
    endif ()
endfunction()

function(_CmDepRegistrySet name src version hash use_system by)
    set_property(GLOBAL PROPERTY CMDEP_REG_${name}_SOURCE_DIR "${src}")
    set_property(GLOBAL PROPERTY CMDEP_REG_${name}_VERSION "${version}")
    set_property(GLOBAL PROPERTY CMDEP_REG_${name}_HASH "${hash}")
    set_property(GLOBAL PROPERTY CMDEP_REG_${name}_USE_SYSTEM "${use_system}")
    set_property(GLOBAL PROPERTY CMDEP_REG_${name}_BY "${by}")
endfunction()

# Who is declaring right now (for messages).
function(_CmDepDeclarer out_var)
    get_property(_in_root GLOBAL PROPERTY CMDEP_IN_ROOT)
    if (PROJECT_NAME)
        set(_who "${PROJECT_NAME}")
    else ()
        set(_who "root")
    endif ()
    set(${out_var} "${_who}" PARENT_SCOPE)
endfunction()

# Compares a root declaration with the lockfile. A stale lock warns (fails with
# CMDEP_LOCKED=ON); a -D override of the declaration is reported but allowed.
function(_CmDepLockCheckRoot name declared_hash effective_hash declared_version)
    get_property(_active GLOBAL PROPERTY CMDEP_LOCK_ACTIVE)
    get_property(_in_root GLOBAL PROPERTY CMDEP_IN_ROOT)
    if (NOT _active OR NOT _in_root)
        return()
    endif ()
    get_property(_locked GLOBAL PROPERTY CMDEP_LOCK_${name}_HASH SET)
    get_property(_lock_file GLOBAL PROPERTY CMDEP_LOCK_FILE_PATH)
    if (NOT _locked)
        message(STATUS "cmake-dep: ${name} is not in ${_lock_file}; run `cmdep lock` to record it")
        return()
    endif ()
    get_property(_lh GLOBAL PROPERTY CMDEP_LOCK_${name}_HASH)
    get_property(_lv GLOBAL PROPERTY CMDEP_LOCK_${name}_VERSION)
    if (NOT declared_hash STREQUAL _lh)
        set(_msg "cmake-dep: ${_lock_file} is out of date: ${name} is ${declared_version} "
                 "(${declared_hash}) in the packages file but ${_lv} (${_lh}) in the lock. Run `cmdep lock`.")
        _CmDepSetting(_strict CMDEP_LOCKED OFF)
        if (_strict)
            message(FATAL_ERROR ${_msg} " (CMDEP_LOCKED is ON)")
        endif ()
        message(WARNING ${_msg})
    elseif (NOT effective_hash STREQUAL declared_hash)
        message(STATUS "cmake-dep: ${name}: -D override in effect (the lock has ${_lv})")
    endif ()
endfunction()

# ---------------------------------------------------------------------------
# LAZY packages: declared now, fetched when something needs the source
# (CmDepAddPackage, a local CmDepBinaryPackage build, or CmDepEnsureSource).
# A binary package served from the cache or a mirror never fetches its source.
# ---------------------------------------------------------------------------
function(_CmDepDeferSource name version locator hash patches)
    set_property(GLOBAL PROPERTY CMDEP_DEFER_${name} TRUE)
    set_property(GLOBAL PROPERTY CMDEP_DEFER_${name}_VERSION "${version}")
    set_property(GLOBAL PROPERTY CMDEP_DEFER_${name}_LOCATOR "${locator}")
    set_property(GLOBAL PROPERTY CMDEP_DEFER_${name}_HASH "${hash}")
    set_property(GLOBAL PROPERTY CMDEP_DEFER_${name}_PATCHES "${patches}")
endfunction()

# CmDepEnsureSource(<name>): fetch a LAZY package's source now (no-op if it is
# already there) and set <name>_SOURCE_DIR in the caller's scope.
function(CmDepEnsureSource name)
    get_property(_deferred GLOBAL PROPERTY CMDEP_DEFER_${name})
    if (_deferred)
        foreach (_f VERSION LOCATOR HASH PATCHES)
            get_property(_${_f} GLOBAL PROPERTY CMDEP_DEFER_${name}_${_f})
        endforeach ()
        _CmDepPopulate(_src ${name} "${_VERSION}" "${_LOCATOR}" "${_HASH}")
        if (_PATCHES)
            _CmDepPatch(_src ${name} "${_src}" ${_PATCHES})
        endif ()
        set_property(GLOBAL PROPERTY CMDEP_REG_${name}_SOURCE_DIR "${_src}")
        set_property(GLOBAL PROPERTY CMDEP_DEFER_${name} FALSE)
    endif ()
    get_property(_registered GLOBAL PROPERTY CMDEP_REG_${name}_SOURCE_DIR SET)
    if (_registered)
        get_property(_src GLOBAL PROPERTY CMDEP_REG_${name}_SOURCE_DIR)
    else ()
        set(_src "${${name}_SOURCE_DIR}")
    endif ()
    set(${name}_SOURCE_DIR "${_src}" PARENT_SCOPE)
endfunction()

# Populates (or, for LAZY, defers) a declared package; sets _cmdep_src.
# Not a function: patch paths are relative to CMAKE_CURRENT_LIST_DIR, which
# must be the packages file's.
macro(_CmDepPopulateOrDefer name lazy version locator hash patches)
    set(_cmdep_patch_files "")
    foreach (_cmdep_p IN ITEMS ${patches})
        get_filename_component(_cmdep_p "${_cmdep_p}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_LIST_DIR}")
        list(APPEND _cmdep_patch_files "${_cmdep_p}")
    endforeach ()
    if (${lazy} AND NOT CMDEP_MIRROR_OUT)
        _CmDepDeferSource(${name} "${version}" "${locator}" "${hash}" "${_cmdep_patch_files}")
        set(_cmdep_src "")
    else ()
        _CmDepPopulate(_cmdep_src ${name} "${version}" "${locator}" "${hash}")
        if (_cmdep_patch_files AND NOT CMDEP_MIRROR_OUT)
            _CmDepPatch(_cmdep_src ${name} "${_cmdep_src}" ${_cmdep_patch_files})
        endif ()
    endif ()
endmacro()

# CmDepFetchPackage(<name> <version> <url> <ALGO=HEX> [PATCHES <file>...] [LAZY])
# PATCHES paths are relative to the packages file. LAZY: fetch only when needed.
macro(CmDepFetchPackage name version url url_hash)
    get_property(_cmdep_collecting GLOBAL PROPERTY CMDEP_COLLECTING)
    if (_cmdep_collecting)
        _CmDepCollect(ARCHIVE "${name}" "${version}" "${url}" "${url_hash}" ${ARGN})
    else ()
        _CmDepFetchPackageImpl("${name}" "${version}" "${url}" "${url_hash}" ${ARGN})
    endif ()
endmacro()

# Sets <name>_SOURCE_DIR/_VERSION/_USE_SYSTEM/_HASH in the calling scope (and,
# like the fetch macros always did, in its parent scope).
macro(_CmDepExportPackageVars name src version use_system hash)
    set(${name}_SOURCE_DIR "${src}")
    set(${name}_VERSION "${version}")
    set(${name}_USE_SYSTEM "${use_system}")
    set(${name}_HASH "${hash}")
    set(${name}_SOURCE_DIR "${src}" PARENT_SCOPE)
    set(${name}_VERSION "${version}" PARENT_SCOPE)
    set(${name}_USE_SYSTEM "${use_system}" PARENT_SCOPE)
    set(${name}_HASH "${hash}" PARENT_SCOPE)
endmacro()

# Reuses a registered package if <name> is already resolved. Sets
# _cmdep_reused to TRUE when it did.
macro(_CmDepReuseRegistered name requested_version requested_hash)
    set(_cmdep_reused FALSE)
    _CmDepRegistryGet(${name} _cmdep_reg_found)
    if (_cmdep_reg_found)
        set(_cmdep_reused TRUE)
        if (NOT "${requested_hash}" STREQUAL "${_cmdep_reg_HASH}")
            _CmDepDeclarer(_cmdep_who)
            message(STATUS "cmake-dep: ${name}: ${_cmdep_who} asks for ${requested_version}; using "
                           "${_cmdep_reg_VERSION} (from ${_cmdep_reg_BY}) so the build has one copy")
        endif ()
        _CmDepExportPackageVars(${name} "${_cmdep_reg_SOURCE_DIR}" "${_cmdep_reg_VERSION}"
            "${_cmdep_reg_USE_SYSTEM}" "${_cmdep_reg_HASH}")
    endif ()
endmacro()

macro(_CmDepFetchPackageImpl name version url url_hash)
    cmake_parse_arguments(_cmdep_fp "LAZY" "" "PATCHES" ${ARGN})
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
    set(_cmdep_eff_hash "${_cmdep_algo}=${${_cmdep_var_hash}}")

    _CmDepLockCheckRoot(${name} "${url_hash}" "${_cmdep_eff_hash}" "${version}")
    _CmDepReuseRegistered(${name} "${_cmdep_eff_version}" "${_cmdep_eff_hash}")
    if (NOT _cmdep_reused)
        set(_cmdep_src "")
        if (_cmdep_use_system)
            if (CMAKE_SCRIPT_MODE_FILE)
                message(STATUS "cmake-dep: ${name}: USE_SYSTEM set, skipping download")
            endif ()
        else ()
            _CmDepPopulateOrDefer(${name} _cmdep_fp_LAZY "${_cmdep_eff_version}"
                "${${_cmdep_var_url}}" "${_cmdep_eff_hash}" "${_cmdep_fp_PATCHES}")
        endif ()
        _CmDepDeclarer(_cmdep_who)
        _CmDepRegistrySet(${name} "${_cmdep_src}" "${_cmdep_eff_version}" "${_cmdep_eff_hash}"
            "${_cmdep_use_system}" "${_cmdep_who}")
        _CmDepExportPackageVars(${name} "${_cmdep_src}" "${_cmdep_eff_version}"
            "${_cmdep_use_system}" "${_cmdep_eff_hash}")
    endif ()
endmacro()

# CmDepFetchGit(<name> <version> <repo> <commit> [ALGO=HEX] [PATCHES <file>...] [LAZY])
#
# A dependency pinned to a git commit (full 40/64-hex id; tags and branches are
# mutable, so they are not accepted). With a hash -- printed on first use, or
# written by `cmdep add --git` -- it is an ordinary hash-addressed archive:
# cached, mirrored, pushed. Without one it is fetched straight from <repo> with
# git (which verifies the commit id); mirrors are not used.
#
# Knobs: <PREFIX>_<DEP>_VERSION, _GIT_URL, _COMMIT, _SHA256 and
# <PREFIX>_USE_SYSTEM_<DEP>, like CmDepFetchPackage.
macro(CmDepFetchGit name version repo commit)
    get_property(_cmdep_collecting GLOBAL PROPERTY CMDEP_COLLECTING)
    if (_cmdep_collecting)
        _CmDepCollect(GIT "${name}" "${version}" "${repo}" "${commit}" ${ARGN})
    else ()
        _CmDepFetchGitImpl("${name}" "${version}" "${repo}" "${commit}" ${ARGN})
    endif ()
endmacro()

# Validates a commit id (CMake regexes have no {n}, hence the length check).
function(_CmDepCheckCommit name commit)
    string(LENGTH "${commit}" _len)
    if (NOT commit MATCHES "^[0-9a-f]+$" OR NOT (_len EQUAL 40 OR _len EQUAL 64))
        message(FATAL_ERROR "cmake-dep: CmDepFetchGit(${name}): '${commit}' is not a full commit id. "
                            "Pin a commit, not a branch or tag (git rev-parse <tag>^{commit}).")
    endif ()
endfunction()

# The archive hash of an unpinned git dependency (cloning it if needed).
function(_CmDepUnpinnedGitHash out_hex name repo commit)
    _CmDepMirrorList(_sources)
    list(FIND _sources direct _direct)
    if (_direct EQUAL -1)
        message(FATAL_ERROR "cmake-dep: ${name}: an unpinned git dependency must be cloned from "
                            "${repo}, but 'direct' is not in CMDEP_MIRRORS. Pin it "
                            "(SHA256=..., see `cmdep add --git`) so mirrors can serve it.")
    endif ()
    _CmDepGitArchiveHash(_hex ${name} "${repo}" "${commit}")
    message(STATUS "cmake-dep: ${name}: pin it to use mirrors -- add SHA256=${_hex} "
                   "to CmDepFetchGit(${name} ...)")
    set(${out_hex} "${_hex}" PARENT_SCOPE)
endfunction()

macro(_CmDepFetchGitImpl name version repo commit)
    cmake_parse_arguments(_cmdep_fg "LAZY" "" "PATCHES" ${ARGN})
    _CmDepProjectPrefix(_cmdep_prefix)
    string(TOUPPER "${name}" _cmdep_dep)
    string(MAKE_C_IDENTIFIER "${_cmdep_dep}" _cmdep_dep)
    set(_cmdep_fg_hash "")
    foreach (_cmdep_a IN LISTS _cmdep_fg_UNPARSED_ARGUMENTS)
        if (_cmdep_a MATCHES "^[A-Za-z0-9_]+=[0-9a-fA-F]+$")
            set(_cmdep_fg_hash "${_cmdep_a}")
        else ()
            message(FATAL_ERROR "cmake-dep: CmDepFetchGit(${name}): unexpected argument '${_cmdep_a}'")
        endif ()
    endforeach ()

    set(${_cmdep_prefix}_${_cmdep_dep}_VERSION "${version}" CACHE STRING "Version of ${name}")
    set(${_cmdep_prefix}_${_cmdep_dep}_GIT_URL "${repo}" CACHE STRING "Git repository of ${name}")
    set(${_cmdep_prefix}_${_cmdep_dep}_COMMIT "${commit}" CACHE STRING "Git commit of ${name}")
    string(REGEX REPLACE "^[^=]*=" "" _cmdep_fg_hex "${_cmdep_fg_hash}")
    set(${_cmdep_prefix}_${_cmdep_dep}_SHA256 "${_cmdep_fg_hex}" CACHE STRING "SHA256 of the archive of ${name}'s commit (optional)")
    option(${_cmdep_prefix}_USE_SYSTEM_${_cmdep_dep} "Use a system-installed ${name} instead of fetching" OFF)

    set(_cmdep_eff_version "${${_cmdep_prefix}_${_cmdep_dep}_VERSION}")
    set(_cmdep_fg_repo "${${_cmdep_prefix}_${_cmdep_dep}_GIT_URL}")
    set(_cmdep_fg_commit "${${_cmdep_prefix}_${_cmdep_dep}_COMMIT}")
    set(_cmdep_fg_hex "${${_cmdep_prefix}_${_cmdep_dep}_SHA256}")
    set(_cmdep_use_system "${${_cmdep_prefix}_USE_SYSTEM_${_cmdep_dep}}")
    string(TOLOWER "${_cmdep_fg_commit}" _cmdep_fg_commit)
    _CmDepCheckCommit(${name} "${_cmdep_fg_commit}")

    # Pinned: compare with the lock like an archive. Unpinned: identity is the
    # commit until its hash is known.
    if (NOT _cmdep_use_system AND _cmdep_fg_hex STREQUAL "")
        _CmDepRegistryGet(${name} _cmdep_reg_found)
        if (NOT _cmdep_reg_found)
            _CmDepUnpinnedGitHash(_cmdep_fg_hex ${name} "${_cmdep_fg_repo}" "${_cmdep_fg_commit}")
        endif ()
    endif ()
    set(_cmdep_eff_hash "SHA256=${_cmdep_fg_hex}")
    if (_cmdep_fg_hash)
        _CmDepLockCheckRoot(${name} "${_cmdep_fg_hash}" "${_cmdep_eff_hash}" "${version}")
    endif ()

    _CmDepReuseRegistered(${name} "${_cmdep_eff_version}" "${_cmdep_eff_hash}")
    if (NOT _cmdep_reused)
        set(_cmdep_src "")
        if (_cmdep_use_system)
            if (CMAKE_SCRIPT_MODE_FILE)
                message(STATUS "cmake-dep: ${name}: USE_SYSTEM set, skipping download")
            endif ()
        else ()
            _CmDepPopulateOrDefer(${name} _cmdep_fg_LAZY "${_cmdep_eff_version}"
                "git+${_cmdep_fg_repo}#${_cmdep_fg_commit}" "${_cmdep_eff_hash}" "${_cmdep_fg_PATCHES}")
        endif ()
        _CmDepDeclarer(_cmdep_who)
        _CmDepRegistrySet(${name} "${_cmdep_src}" "${_cmdep_eff_version}" "${_cmdep_eff_hash}"
            "${_cmdep_use_system}" "${_cmdep_who}")
        _CmDepExportPackageVars(${name} "${_cmdep_src}" "${_cmdep_eff_version}"
            "${_cmdep_use_system}" "${_cmdep_eff_hash}")
    endif ()
endmacro()

# Whether the system copy of <name> was requested. Follows the registry, so the
# project that resolved a package (normally the root) decides for everyone.
function(CmDepUseSystem name out_var)
    get_property(_reg GLOBAL PROPERTY CMDEP_REG_${name}_USE_SYSTEM SET)
    if (_reg)
        get_property(_us GLOBAL PROPERTY CMDEP_REG_${name}_USE_SYSTEM)
    else ()
        _CmDepProjectPrefix(_p)
        string(TOUPPER "${name}" _d)
        string(MAKE_C_IDENTIFIER "${_d}" _d)
        set(_us "${${_p}_USE_SYSTEM_${_d}}")
    endif ()
    if (_us)
        set(${out_var} ON PARENT_SCOPE)
    else ()
        set(${out_var} OFF PARENT_SCOPE)
    endif ()
endfunction()

macro(CmDepFetchFile name version url destination_name url_hash)
    get_property(_cmdep_collecting GLOBAL PROPERTY CMDEP_COLLECTING)
    if (NOT _cmdep_collecting)
        _CmDepPopulate(_cmdep_src ${name} "${version}" "${url}" "${url_hash}"
            KIND FILE FILE_NAME "${destination_name}")
        set(${name}_SOURCE_DIR "${_cmdep_src}")
        set(${name}_VERSION "${version}")
        set(${name}_SOURCE_DIR "${_cmdep_src}" PARENT_SCOPE)
        set(${name}_VERSION "${version}" PARENT_SCOPE)
    endif ()
endmacro()

# Default lockfile for a packages file: cmdep.lock next to it.
function(_CmDepLockFileFor out_var packages_file)
    _CmDepSetting(_lf CMDEP_LOCK_FILE "")
    if (_lf STREQUAL "")
        get_filename_component(_dir "${packages_file}" DIRECTORY)
        set(_lf "${_dir}/cmdep.lock")
    endif ()
    set(${out_var} "${_lf}" PARENT_SCOPE)
endfunction()

# Processes <packages_file> as the root of the build (the first CmDepFetch()):
# loads its lockfile if there is one, processes the declarations (checking them
# against the lock), then fetches the locked transitive packages so every
# dependency that declares them gets the locked copy.
macro(_CmDepFetchRoot packages_file)
    _CmDepLockFileFor(_cmdep_lockfile "${packages_file}")
    # Read CMDEP_LOCKED here, not only on a mismatch: with -DCMDEP_LOCKED=ON CMake
    # would otherwise report it as unused, and a missing lock must fail too.
    _CmDepSetting(_cmdep_locked CMDEP_LOCKED OFF)
    if (EXISTS "${_cmdep_lockfile}")
        _CmDepLoadLock("${_cmdep_lockfile}")
    elseif (_cmdep_locked)
        message(FATAL_ERROR "cmake-dep: CMDEP_LOCKED is ON but there is no lockfile (${_cmdep_lockfile}). "
                            "Run `cmdep lock` and commit cmdep.lock.")
    endif ()
    set_property(GLOBAL PROPERTY CMDEP_IN_ROOT TRUE)
    include("${packages_file}")
    set_property(GLOBAL PROPERTY CMDEP_IN_ROOT FALSE)
    get_property(_cmdep_lock_active GLOBAL PROPERTY CMDEP_LOCK_ACTIVE)
    if (_cmdep_lock_active)
        get_filename_component(_cmdep_root_dir "${packages_file}" DIRECTORY)
        _CmDepApplyLock("${_cmdep_root_dir}")
    endif ()
endmacro()

function(CmDepFetch)
    if (NOT DEFINED CMDEP_PACKAGES_FILE)
        if (EXISTS "${PROJECT_SOURCE_DIR}/cmdep-packages.cmake")
            set(CMDEP_PACKAGES_FILE "${PROJECT_SOURCE_DIR}/cmdep-packages.cmake")
        else ()
            message(FATAL_ERROR "CMDEP_PACKAGES_FILE must be set before calling CmDepFetch() "
                                "(or create ${PROJECT_SOURCE_DIR}/cmdep-packages.cmake)")
        endif ()
    endif ()
    get_filename_component(_cmdep_pf "${CMDEP_PACKAGES_FILE}" ABSOLUTE)
    get_property(_cmdep_root_done GLOBAL PROPERTY CMDEP_ROOT_DONE)
    if (NOT _cmdep_root_done)
        set_property(GLOBAL PROPERTY CMDEP_ROOT_DONE TRUE)
        _CmDepFetchRoot("${_cmdep_pf}")
    else ()
        include("${_cmdep_pf}")
    endif ()
endfunction()

include("${CMAKE_CURRENT_LIST_DIR}/CmDepLock.cmake")
