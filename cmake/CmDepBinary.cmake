# Binary packages: build a fetched dependency once, share the installed result.
#
#   CmDepFetchPackage(qtbase v6.8.1 <url> SHA256=<hash>)
#   CmDepBinaryPackage(qtbase
#       CMAKE_ARGS   -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF
#       FIND_PACKAGE Qt6 REQUIRED COMPONENTS Core Gui Widgets)
#
# The installed prefix is identified by a *build key*: a hash of everything that
# affects the binaries (source hash, CMAKE_ARGS, toolchain, platform, configs,
# dependencies' keys, KEY_VARS). It lives in the shared cache at
#   <cache>/bin/<name>-<version>-<key12>/
# and is looked up, in order:
#   1. that local directory (complete when stamped)
#   2. each CMDEP_BINARY_MIRRORS entry: <mirror>/bin/<key>.tar.zst (+ .sha256)
#   3. a local build, at configure time (unless CMDEP_BINARIES=require)
# A local build is pushed to CMDEP_BINARY_PUSH if set. Then find_package runs
# against the prefix, so imported targets exist at configure time (AUTOMOC etc.).
#
# See docs/binary-packages.md.

# Policies for cmake-dep's own code, so it behaves the same in a configure and
# in a bare `cmake -P` (include() keeps this from leaking into the includer).
cmake_policy(VERSION 3.18)


include("${CMAKE_CURRENT_LIST_DIR}/CmDepFetch.cmake")

# The part of the build key describing the machine/toolchain. CMDEP_BINARY_PLATFORM
# replaces the auto-detected value, e.g. when a team builds in one Docker image
# and wants keys that ignore patch-level compiler differences.
function(_CmDepBinaryPlatform out_var)
    _CmDepSetting(_p CMDEP_BINARY_PLATFORM "")
    if (NOT _p STREQUAL "")
        set(${out_var} "${_p}" PARENT_SCOPE)
        return()
    endif ()
    set(_parts "${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}")
    foreach (_lang C CXX)
        if (CMAKE_${_lang}_COMPILER_ID)
            list(APPEND _parts "${_lang}=${CMAKE_${_lang}_COMPILER_ID}-${CMAKE_${_lang}_COMPILER_VERSION}")
        endif ()
    endforeach ()
    if (CMAKE_SYSTEM_NAME STREQUAL "Linux" AND NOT CMAKE_CROSSCOMPILING)
        get_property(_libc GLOBAL PROPERTY CMDEP_HOST_LIBC)
        if (NOT _libc)
            execute_process(COMMAND getconf GNU_LIBC_VERSION
                OUTPUT_VARIABLE _libc OUTPUT_STRIP_TRAILING_WHITESPACE
                ERROR_QUIET RESULT_VARIABLE _r)
            if (NOT _r EQUAL 0 OR _libc STREQUAL "")
                set(_libc "libc-unknown")
            endif ()
            string(REPLACE " " "-" _libc "${_libc}")
            set_property(GLOBAL PROPERTY CMDEP_HOST_LIBC "${_libc}")
        endif ()
        list(APPEND _parts "${_libc}")
    endif ()
    string(REPLACE ";" "/" _p "${_parts}")
    set(${out_var} "${_p}" PARENT_SCOPE)
endfunction()

# Configurations to build: CONFIGS if given; else Release+Debug for a
# multi-config parent generator; else Debug or Release following
# CMAKE_BUILD_TYPE (anything but Debug maps to Release, as CmDepBuildExternal does).
function(_CmDepBinaryConfigs out_var explicit)
    if (explicit)
        set(_c ${explicit})
    else ()
        get_property(_multi GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
        if (_multi)
            set(_c Release Debug)
        elseif (CMAKE_BUILD_TYPE STREQUAL "Debug")
            set(_c Debug)
        else ()
            set(_c Release)
        endif ()
    endif ()
    set(${out_var} "${_c}" PARENT_SCOPE)
endfunction()

# Toolchain-related settings forwarded to the dependency's build. They are part
# of the key, so they are collected in one place.
function(_CmDepBinaryToolchainVars out_var)
    set(_vars "")
    foreach (_v CMAKE_C_COMPILER CMAKE_CXX_COMPILER CMAKE_TOOLCHAIN_FILE
                CMAKE_MSVC_RUNTIME_LIBRARY CMAKE_OSX_ARCHITECTURES
                CMAKE_OSX_DEPLOYMENT_TARGET CMAKE_OSX_SYSROOT
                CMAKE_POSITION_INDEPENDENT_CODE CMAKE_SYSROOT)
        if (DEFINED ${_v} AND NOT "${${_v}}" STREQUAL "")
            list(APPEND _vars ${_v})
        endif ()
    endforeach ()
    set(${out_var} "${_vars}" PARENT_SCOPE)
endfunction()

function(_CmDepBinaryGenerator out_gen out_multi configs explicit)
    if (explicit)
        set(_gen "${explicit}")
    else ()
        find_program(CMDEP_NINJA_PROGRAM NAMES ninja ninja-build)
        mark_as_advanced(CMDEP_NINJA_PROGRAM)
        list(LENGTH configs _n)
        if (CMDEP_NINJA_PROGRAM)
            if (_n GREATER 1)
                set(_gen "Ninja Multi-Config")
            else ()
                set(_gen "Ninja")
            endif ()
        else ()
            set(_gen "${CMAKE_GENERATOR}")
        endif ()
    endif ()
    if (_gen MATCHES "Multi-Config|^Visual Studio|^Xcode")
        set(${out_multi} TRUE PARENT_SCOPE)
    else ()
        set(${out_multi} FALSE PARENT_SCOPE)
    endif ()
    set(${out_gen} "${_gen}" PARENT_SCOPE)
endfunction()

# Runs one build step, logging to <log>; fails with the log's tail.
function(_CmDepBinaryStep name what log)
    execute_process(COMMAND ${ARGN} RESULT_VARIABLE _r OUTPUT_FILE "${log}" ERROR_FILE "${log}.err")
    if (NOT _r EQUAL 0)
        file(READ "${log}" _out)
        file(READ "${log}.err" _err)
        string(LENGTH "${_out}${_err}" _len)
        set(_tail "${_out}${_err}")
        if (_len GREATER 4000)
            math(EXPR _start "${_len} - 4000")
            string(SUBSTRING "${_tail}" ${_start} -1 _tail)
        endif ()
        message(FATAL_ERROR "cmake-dep: ${name}: ${what} failed (exit ${_r}).\n"
                            "Full log: ${log} (+ .err)\n...\n${_tail}")
    endif ()
endfunction()

# Text files that may legitimately carry an install path.
# Rewrites the absolute path <from> to <to> in the text files of <dir>
# (CMake package files, .pc, .prl, ...). Installed packages often embed their
# install prefix; since a binary package is moved into the cache and onto other
# machines, those paths must follow it. Binary files are not touched -- a
# library that hard-codes its prefix in machine code is not relocatable.
# With STRICT, any such file is an error instead.
function(_CmDepBinaryRelocate name dir from to)
    cmake_parse_arguments(PARSE_ARGV 4 _R "STRICT" "" "")
    if (from STREQUAL to)
        return()
    endif ()
    file(GLOB_RECURSE _files LIST_DIRECTORIES false "${dir}/*")
    set(_hits "")
    foreach (_f IN LISTS _files)
        if (NOT _f MATCHES "\\.(cmake|pc|prl|pri|la|conf|cfg|ini|json|txt|sh|bat|cmd|py|pl|qmake)$")
            continue()
        endif ()
        file(READ "${_f}" _content)
        string(FIND "${_content}" "${from}" _pos)
        if (_pos EQUAL -1)
            continue()
        endif ()
        file(RELATIVE_PATH _rel "${dir}" "${_f}")
        list(APPEND _hits "${_rel}")
        if (NOT _R_STRICT)
            string(REPLACE "${from}" "${to}" _content "${_content}")
            file(WRITE "${_f}" "${_content}")
        endif ()
    endforeach ()
    if (NOT _hits)
        return()
    endif ()
    list(LENGTH _hits _n)
    string(REPLACE ";" "\n  " _list "${_hits}")
    if (_R_STRICT)
        message(FATAL_ERROR "cmake-dep: ${name}: the installed package is not relocatable -- these files "
                            "contain the absolute install prefix (${from}):\n  ${_list}\n"
                            "Use relative paths (install(EXPORT), configure_package_config_file), or drop "
                            "NO_PATH_REWRITE to let cmake-dep rewrite them.")
    endif ()
    message(VERBOSE "cmake-dep: ${name}: rewrote the install prefix in ${_n} file(s):\n  ${_list}")
endfunction()

# Builds <src> and installs it into <prefix>, at configure time.
function(_CmDepBinaryBuild name src prefix work configs gen multi cmake_args prefix_path)
    # Forwarded settings go through an initial-cache file, which sidesteps all
    # quoting/list issues of passing them on a command line.
    set(_init "")
    _CmDepBinaryToolchainVars(_tvars)
    foreach (_v IN LISTS _tvars)
        string(APPEND _init "set(${_v} [==[${${_v}}]==] CACHE STRING \"\")\n")
    endforeach ()
    string(APPEND _init "set(CMAKE_INSTALL_PREFIX [==[${prefix}]==] CACHE PATH \"\")\n")
    string(APPEND _init "set(CMAKE_INSTALL_MESSAGE NEVER CACHE STRING \"\")\n")
    if (prefix_path)
        string(APPEND _init "set(CMAKE_PREFIX_PATH [==[${prefix_path}]==] CACHE STRING \"\")\n")
    endif ()
    if (multi)
        string(APPEND _init "set(CMAKE_CONFIGURATION_TYPES [==[${configs}]==] CACHE STRING \"\")\n")
    endif ()
    if (gen MATCHES "^Ninja" AND CMDEP_NINJA_PROGRAM)
        string(APPEND _init "set(CMAKE_MAKE_PROGRAM [==[${CMDEP_NINJA_PROGRAM}]==] CACHE FILEPATH \"\")\n")
    endif ()
    file(WRITE "${work}/init-cache.cmake" "${_init}")

    set(_gen_args -G "${gen}")
    if (gen STREQUAL CMAKE_GENERATOR)
        if (CMAKE_GENERATOR_PLATFORM)
            list(APPEND _gen_args -A "${CMAKE_GENERATOR_PLATFORM}")
        endif ()
        if (CMAKE_GENERATOR_TOOLSET)
            list(APPEND _gen_args -T "${CMAKE_GENERATOR_TOOLSET}")
        endif ()
    endif ()

    _CmDepSetting(_jobs CMDEP_BINARY_JOBS "")
    if (_jobs STREQUAL "")
        if (DEFINED ENV{CMAKE_BUILD_PARALLEL_LEVEL})
            set(_jobs "$ENV{CMAKE_BUILD_PARALLEL_LEVEL}")
        else ()
            cmake_host_system_information(RESULT _jobs QUERY NUMBER_OF_LOGICAL_CORES)
        endif ()
    endif ()

    if (multi)
        set(_builds "multi")
    else ()
        set(_builds ${configs})
    endif ()
    foreach (_b IN LISTS _builds)
        set(_bdir "${work}/build-${_b}")
        if (multi)
            set(_cfg_arg "-DCMDEP_MULTI_CONFIG=ON")  # types come from init-cache.cmake
            set(_cfgs ${configs})
        else ()
            set(_cfg_arg "-DCMAKE_BUILD_TYPE=${_b}")
            set(_cfgs ${_b})
        endif ()
        message(STATUS "cmake-dep: ${name}: configuring (${gen}, ${_b})")
        _CmDepBinaryStep(${name} "configure" "${work}/configure-${_b}.log"
            ${CMAKE_COMMAND} -S "${src}" -B "${_bdir}" ${_gen_args}
            -C "${work}/init-cache.cmake" "${_cfg_arg}" ${cmake_args})
        foreach (_cfg IN LISTS _cfgs)
            message(STATUS "cmake-dep: ${name}: building ${_cfg} with ${_jobs} jobs "
                           "(log: ${work}/build-${_cfg}.log)")
            _CmDepBinaryStep(${name} "build (${_cfg})" "${work}/build-${_cfg}.log"
                ${CMAKE_COMMAND} --build "${_bdir}" --config ${_cfg} --parallel ${_jobs})
            _CmDepBinaryStep(${name} "install (${_cfg})" "${work}/install-${_cfg}.log"
                ${CMAKE_COMMAND} --install "${_bdir}" --config ${_cfg})
        endforeach ()
    endforeach ()
endfunction()

# ---------------------------------------------------------------------------
# Signing (ssh-keygen -Y)
#
# CI signs each package's .sha256 sidecar (which names the build key and the
# tarball's hash) with CMDEP_BINARY_SIGNING_KEY. Clients that set
# CMDEP_BINARY_TRUSTED_KEYS (an ssh allowed_signers file) only accept binaries
# whose signature verifies against it.
# ---------------------------------------------------------------------------
function(_CmDepSshKeygen out_var)
    find_program(CMDEP_SSH_KEYGEN NAMES ssh-keygen
        PATHS "$ENV{SystemRoot}/System32/OpenSSH" "C:/Windows/System32/OpenSSH")
    mark_as_advanced(CMDEP_SSH_KEYGEN)
    set(${out_var} "${CMDEP_SSH_KEYGEN}" PARENT_SCOPE)
endfunction()

# Signs <file> into <file>.sig. Sets out_ok.
function(_CmDepBinarySign out_ok file key)
    _CmDepSshKeygen(_kg)
    if (NOT _kg)
        message(WARNING "cmake-dep: CMDEP_BINARY_SIGNING_KEY is set but ssh-keygen was not found")
        set(${out_ok} FALSE PARENT_SCOPE)
        return()
    endif ()
    file(REMOVE "${file}.sig")
    execute_process(COMMAND "${_kg}" -Y sign -f "${key}" -n cmake-dep-binary "${file}"
        RESULT_VARIABLE _r OUTPUT_QUIET ERROR_VARIABLE _e)
    if (_r EQUAL 0 AND EXISTS "${file}.sig")
        set(${out_ok} TRUE PARENT_SCOPE)
    else ()
        message(WARNING "cmake-dep: signing with ${key} failed: ${_e}")
        set(${out_ok} FALSE PARENT_SCOPE)
    endif ()
endfunction()

# Verifies <sig> over <file> against the allowed_signers file <trusted>.
# Sets out_ok, out_msg (the signer on success, the reason otherwise).
function(_CmDepBinaryVerify out_ok out_msg file sig trusted)
    _CmDepSshKeygen(_kg)
    if (NOT _kg)
        set(${out_ok} FALSE PARENT_SCOPE)
        set(${out_msg} "ssh-keygen not found, cannot verify signatures" PARENT_SCOPE)
        return()
    endif ()
    execute_process(COMMAND "${_kg}" -Y find-principals -s "${sig}" -f "${trusted}"
        RESULT_VARIABLE _r OUTPUT_VARIABLE _principals ERROR_VARIABLE _e)
    if (NOT _r EQUAL 0)
        set(${out_ok} FALSE PARENT_SCOPE)
        set(${out_msg} "signed by a key that is not in ${trusted}" PARENT_SCOPE)
        return()
    endif ()
    string(REGEX REPLACE "[\r\n].*" "" _principal "${_principals}")
    execute_process(COMMAND "${_kg}" -Y verify -f "${trusted}" -I "${_principal}" -n cmake-dep-binary -s "${sig}"
        INPUT_FILE "${file}" RESULT_VARIABLE _r OUTPUT_QUIET ERROR_VARIABLE _e)
    if (_r EQUAL 0)
        set(${out_ok} TRUE PARENT_SCOPE)
        set(${out_msg} "${_principal}" PARENT_SCOPE)
    else ()
        string(STRIP "${_e}" _e)
        set(${out_ok} FALSE PARENT_SCOPE)
        set(${out_msg} "bad signature (${_e})" PARENT_SCOPE)
    endif ()
endfunction()

# Fetches <mirror>/bin/<key>.tar.zst from CMDEP_BINARY_MIRRORS into <work>/prefix.
# The .sha256 sidecar is pushed last, so its presence marks a complete upload
# and it guards against truncated/corrupt transfers. (It does not make a
# mirror trustworthy -- see docs/binary-packages.md, "Trust".)
function(_CmDepBinaryFromMirrors out_source name key work dest)
    set(${out_source} "" PARENT_SCOPE)
    _CmDepSetting(_mirrors CMDEP_BINARY_MIRRORS "")
    string(REPLACE "," ";" _mirrors "${_mirrors}")
    foreach (_m IN LISTS _mirrors)
        string(STRIP "${_m}" _m)
        string(REGEX REPLACE "/+$" "" _m "${_m}")
        if (_m STREQUAL "")
            continue()
        endif ()
        get_property(_dead GLOBAL PROPERTY CMDEP_DEAD_MIRRORS)
        list(FIND _dead "${_m}" _i)
        if (NOT _i EQUAL -1)
            continue()
        endif ()
        _CmDepTryFetch(_st _msg "${_m}/bin/${key}.tar.zst.sha256" "${work}/bin.sha256" NONE "" TRUE)
        if (_st STREQUAL "DEAD")
            set_property(GLOBAL APPEND PROPERTY CMDEP_DEAD_MIRRORS "${_m}")
            message(STATUS "cmake-dep: mirror ${_m} unreachable (${_msg}); skipping it for the rest of this run")
            continue()
        elseif (NOT _st STREQUAL "OK")
            message(VERBOSE "cmake-dep: ${name}: no binary on ${_m}")
            continue()
        endif ()
        _CmDepSetting(_trusted CMDEP_BINARY_TRUSTED_KEYS "")
        if (_trusted)
            _CmDepTryFetch(_st _msg "${_m}/bin/${key}.tar.zst.sha256.sig" "${work}/bin.sha256.sig" NONE "" TRUE)
            if (NOT _st STREQUAL "OK")
                message(STATUS "cmake-dep: ${name}: binary on ${_m} is unsigned; ignored "
                               "(CMDEP_BINARY_TRUSTED_KEYS is set)")
                continue()
            endif ()
            _CmDepBinaryVerify(_vok _vmsg "${work}/bin.sha256" "${work}/bin.sha256.sig" "${_trusted}")
            file(REMOVE "${work}/bin.sha256.sig")
            if (NOT _vok)
                message(STATUS "cmake-dep: ${name}: binary on ${_m} rejected: ${_vmsg}")
                continue()
            endif ()
            message(STATUS "cmake-dep: ${name}: signature verified (signed by ${_vmsg})")
        endif ()
        file(STRINGS "${work}/bin.sha256" _sha LIMIT_COUNT 1 REGEX "^[0-9a-fA-F]+")
        string(REGEX MATCH "^[0-9a-fA-F]+" _sha "${_sha}")
        string(TOLOWER "${_sha}" _sha)
        message(STATUS "cmake-dep: ${name}: downloading binary from ${_m}")
        _CmDepTryFetch(_st _msg "${_m}/bin/${key}.tar.zst" "${work}/bin.tar.zst" SHA256 "${_sha}" TRUE)
        if (_st STREQUAL "DEAD")
            set_property(GLOBAL APPEND PROPERTY CMDEP_DEAD_MIRRORS "${_m}")
        endif ()
        if (NOT _st STREQUAL "OK")
            message(STATUS "cmake-dep: ${name}: binary on ${_m} unusable (${_msg})")
            continue()
        endif ()
        file(REMOVE_RECURSE "${work}/prefix")
        file(MAKE_DIRECTORY "${work}/prefix")
        file(ARCHIVE_EXTRACT INPUT "${work}/bin.tar.zst" DESTINATION "${work}/prefix")
        file(REMOVE "${work}/bin.tar.zst" "${work}/bin.sha256")
        set(_manifest "${work}/prefix/.cmake-dep-binary.txt")
        set(_got "")
        if (EXISTS "${_manifest}")
            file(STRINGS "${_manifest}" _got REGEX "^key=")
        endif ()
        if (NOT _got STREQUAL "key=${key}")
            message(STATUS "cmake-dep: ${name}: binary on ${_m} has the wrong key, ignoring it")
            file(REMOVE_RECURSE "${work}/prefix")
            continue()
        endif ()
        file(STRINGS "${_manifest}" _built REGEX "^prefix=")
        string(REGEX REPLACE "^prefix=" "" _built "${_built}")
        if (_built)
            _CmDepBinaryRelocate(${name} "${work}/prefix" "${_built}" "${dest}")
            file(READ "${_manifest}" _mtext)
            string(REPLACE "prefix=${_built}\n" "prefix=${dest}\n" _mtext "${_mtext}")
            file(WRITE "${_manifest}" "${_mtext}")
        endif ()
        set(${out_source} "${_m}" PARENT_SCOPE)
        return()
    endforeach ()
endfunction()

# Packs <prefix> into <work>/bin.tar.zst (+ .sha256) and pushes both to
# <target>/bin/, sidecar last.
function(_CmDepBinaryPush name key prefix work target)
    string(REGEX REPLACE "/+$" "" target "${target}")
    _CmDepLocalPath(_local "${target}")
    if (_local AND EXISTS "${_local}/bin/${key}.tar.zst.sha256")
        return()
    endif ()
    set(_tar "${work}/bin.tar.zst")
    file(REMOVE "${_tar}")
    execute_process(COMMAND ${CMAKE_COMMAND} -E tar cf "${_tar}" --zstd .
        WORKING_DIRECTORY "${prefix}" RESULT_VARIABLE _r OUTPUT_QUIET ERROR_VARIABLE _err)
    if (NOT _r EQUAL 0)
        message(WARNING "cmake-dep: ${name}: could not pack binary for upload: ${_err}")
        return()
    endif ()
    file(SHA256 "${_tar}" _sha)
    file(WRITE "${_tar}.sha256" "${_sha}  ${key}.tar.zst\n")
    _CmDepSetting(_signing_key CMDEP_BINARY_SIGNING_KEY "")
    set(_signed FALSE)
    if (_signing_key)
        _CmDepBinarySign(_signed "${_tar}.sha256" "${_signing_key}")
        if (NOT _signed)
            message(WARNING "cmake-dep: ${name}: not pushing an unsigned binary (signing failed)")
            file(REMOVE "${_tar}" "${_tar}.sha256")
            return()
        endif ()
    endif ()
    # Order matters: the .sha256 sidecar goes last and marks the upload complete.
    _CmDepPushFile(_ok "${target}" "bin/${key}.tar.zst" "${_tar}" ${name})
    if (_ok AND _signed)
        _CmDepPushFile(_ok "${target}" "bin/${key}.tar.zst.sha256.sig" "${_tar}.sha256.sig" ${name})
    endif ()
    if (_ok)
        _CmDepPushFile(_ok "${target}" "bin/${key}.tar.zst.sha256" "${_tar}.sha256" ${name})
    endif ()
    if (_ok)
        message(STATUS "cmake-dep: ${name}: pushed binary to ${target}")
    endif ()
    file(REMOVE "${_tar}" "${_tar}.sha256" "${_tar}.sha256.sig")
endfunction()

# Makes the binary package for <name> available and sets, in the caller's
# scope: <name>_BINARY_PREFIX, <name>_BINARY_KEY.
function(_CmDepBinaryEnsure name)
    cmake_parse_arguments(PARSE_ARGV 1 _B "NO_PATH_REWRITE" "SOURCE_SUBDIR;GENERATOR"
        "CMAKE_ARGS;FIND_PACKAGE;DEPENDS;KEY_VARS;CONFIGS")

    if (NOT DEFINED ${name}_SOURCE_DIR OR NOT DEFINED ${name}_HASH)
        message(FATAL_ERROR "cmake-dep: CmDepBinaryPackage(${name}): no fetched package '${name}' -- "
                            "call CmDepFetchPackage(${name} ...) (via CmDepFetch()) first")
    endif ()

    # --- build key --------------------------------------------------------
    _CmDepBinaryPlatform(_platform)
    _CmDepBinaryConfigs(_configs "${_B_CONFIGS}")
    _CmDepBinaryToolchainVars(_tvars)
    set(_inputs "format=1\nname=${name}\nversion=${${name}_VERSION}\n")
    string(APPEND _inputs "source=${${name}_HASH}\nplatform=${_platform}\nconfigs=${_configs}\n")
    string(APPEND _inputs "source_subdir=${_B_SOURCE_SUBDIR}\n")
    foreach (_v IN LISTS _tvars)
        if (_v STREQUAL "CMAKE_C_COMPILER" OR _v STREQUAL "CMAKE_CXX_COMPILER")
            continue()  # identity is in `platform`; the path differs per machine
        elseif (_v STREQUAL "CMAKE_TOOLCHAIN_FILE" AND EXISTS "${${_v}}")
            file(SHA256 "${${_v}}" _th)
            string(APPEND _inputs "toolchain_sha256=${_th}\n")
        elseif (_v MATCHES "SYSROOT$")
            get_filename_component(_sr "${${_v}}" NAME)  # SDK name, not its per-machine path
            string(APPEND _inputs "${_v}=${_sr}\n")
        else ()
            string(APPEND _inputs "${_v}=${${_v}}\n")
        endif ()
    endforeach ()
    foreach (_a IN LISTS _B_CMAKE_ARGS)
        string(APPEND _inputs "arg=${_a}\n")
    endforeach ()
    set(_prefix_path "")
    foreach (_d IN LISTS _B_DEPENDS)
        if (NOT ${_d}_BINARY_KEY)
            message(FATAL_ERROR "cmake-dep: CmDepBinaryPackage(${name}): DEPENDS ${_d} is not a "
                                "binary package declared before it")
        endif ()
        string(APPEND _inputs "depends=${_d}:${${_d}_BINARY_KEY}\n")
        list(APPEND _prefix_path "${${_d}_BINARY_PREFIX}")
    endforeach ()
    foreach (_v IN LISTS _B_KEY_VARS)
        string(APPEND _inputs "var:${_v}=${${_v}}\n")
    endforeach ()
    string(SHA256 _key "${_inputs}")
    string(SUBSTRING "${_key}" 0 12 _short)

    CmDepCacheDir(_root)
    set(_entry "${name}-${${name}_VERSION}-${_short}")
    set(_dest "${_root}/bin/${_entry}")
    set(_stamp "${_dest}/.cmake-dep-complete")
    set(${name}_BINARY_PREFIX "${_dest}" PARENT_SCOPE)
    set(${name}_BINARY_KEY "${_key}" PARENT_SCOPE)

    if (EXISTS "${_stamp}")
        _CmDepTouch("${_stamp}")
        return()
    endif ()

    file(MAKE_DIRECTORY "${_root}/.locks" "${_root}/.tmp" "${_root}/bin")
    set(_lock "${_root}/.locks/bin-${_entry}.lock")
    file(LOCK "${_lock}" GUARD FUNCTION TIMEOUT 0 RESULT_VARIABLE _lock_res)
    if (NOT _lock_res EQUAL 0)
        message(STATUS "cmake-dep: ${name}: waiting for another process to finish building/fetching it...")
        file(LOCK "${_lock}" GUARD FUNCTION)
    endif ()
    if (EXISTS "${_stamp}")
        file(LOCK "${_lock}" RELEASE)
        return()
    endif ()
    if (EXISTS "${_dest}")
        message(STATUS "cmake-dep: ${_entry}: incomplete (no stamp), removing")
        file(REMOVE_RECURSE "${_dest}")
    endif ()

    set(_work "${_root}/.tmp/bin-${_entry}")
    file(REMOVE_RECURSE "${_work}")
    file(MAKE_DIRECTORY "${_work}")

    _CmDepSetting(_mode CMDEP_BINARIES "prefer")
    if (NOT _mode MATCHES "^(prefer|require|local)$")
        message(FATAL_ERROR "cmake-dep: CMDEP_BINARIES must be prefer, require or local (got '${_mode}')")
    endif ()

    set(_source "")
    if (NOT _mode STREQUAL "local")
        _CmDepBinaryFromMirrors(_source ${name} ${_key} "${_work}" "${_dest}")
    endif ()

    if (_source STREQUAL "")
        if (_mode STREQUAL "require")
            file(REMOVE_RECURSE "${_work}")
            message(FATAL_ERROR "cmake-dep: ${name}: no prebuilt binary for key ${_key} on any "
                                "CMDEP_BINARY_MIRRORS entry, and CMDEP_BINARIES=require forbids "
                                "building it locally.\nBuild inputs:\n${_inputs}"
                                "Set CMDEP_BINARIES=prefer to build it here.")
        endif ()
        CmDepEnsureSource(${name})  # a LAZY source is only fetched when we must build
        set(_src "${${name}_SOURCE_DIR}")
        if (_B_SOURCE_SUBDIR)
            set(_src "${_src}/${_B_SOURCE_SUBDIR}")
        endif ()
        _CmDepBinaryGenerator(_gen _multi "${_configs}" "${_B_GENERATOR}")
        message(STATUS "cmake-dep: ${name}: no prebuilt binary, building it now (once per machine "
                       "for this configuration; key ${_short})")
        _CmDepBinaryBuild(${name} "${_src}" "${_work}/prefix" "${_work}" "${_configs}"
            "${_gen}" ${_multi} "${_B_CMAKE_ARGS}" "${_prefix_path}")
        if (_B_NO_PATH_REWRITE)
            _CmDepBinaryRelocate(${name} "${_work}/prefix" "${_work}/prefix" "${_dest}" STRICT)
        else ()
            _CmDepBinaryRelocate(${name} "${_work}/prefix" "${_work}/prefix" "${_dest}")
        endif ()
        # prefix= records the path text files now point at, so a machine that
        # downloads this package can rewrite it to its own location.
        file(WRITE "${_work}/prefix/.cmake-dep-binary.txt" "key=${_key}\nprefix=${_dest}\n${_inputs}")
        set(_source "local-build")
    endif ()

    _CmDepSetting(_push CMDEP_BINARY_PUSH "")
    string(REGEX REPLACE "/+$" "" _push "${_push}")
    if (_push AND NOT _source STREQUAL _push)
        _CmDepBinaryPush(${name} ${_key} "${_work}/prefix" "${_work}" "${_push}")
    endif ()

    file(WRITE "${_work}/prefix/.cmake-dep-complete" "source=${_source}\n")
    file(RENAME "${_work}/prefix" "${_dest}")
    file(REMOVE_RECURSE "${_work}")
    if (NOT EXISTS "${_stamp}")
        message(FATAL_ERROR "cmake-dep: ${_entry}: stamp file missing after install (${_stamp}); "
                            "refusing to continue to avoid a rebuild loop")
    endif ()
    message(STATUS "cmake-dep: ${_entry}: ready (${_source})")
    file(LOCK "${_lock}" RELEASE)
endfunction()

# CmDepBinaryPackage(<name>
#     [CMAKE_ARGS <args>...]          arguments for the dependency's configure
#     [FIND_PACKAGE <find_package args>...]  run against the installed prefix
#     [DEPENDS <binary packages>...]  earlier CmDepBinaryPackage()s it builds against
#     [KEY_VARS <vars>...]            extra variables that must change the key
#     [CONFIGS <configs>...]          default: CMAKE_BUILD_TYPE (Debug or Release),
#                                     Release;Debug for multi-config generators
#     [SOURCE_SUBDIR <dir>]           CMakeLists.txt is in a subdirectory
#     [GENERATOR <generator>]         default: Ninja (Multi-Config) if found, else the parent's
#     [NO_PATH_REWRITE])              fail instead of rewriting absolute install paths
#
# Sets <name>_BINARY_PREFIX and <name>_BINARY_KEY and appends the prefix to
# CMAKE_PREFIX_PATH. With <PREFIX>_USE_SYSTEM_<NAME>=ON nothing is built and
# FIND_PACKAGE runs against the system instead.
macro(CmDepBinaryPackage name)
    cmake_parse_arguments(_cmdep_bin "NO_PATH_REWRITE" "SOURCE_SUBDIR;GENERATOR"
        "CMAKE_ARGS;FIND_PACKAGE;DEPENDS;KEY_VARS;CONFIGS" ${ARGN})
    if (${name}_USE_SYSTEM)
        if (_cmdep_bin_FIND_PACKAGE)
            find_package(${_cmdep_bin_FIND_PACKAGE})
        endif ()
    else ()
        _CmDepBinaryEnsure(${name} ${ARGN})
        list(APPEND CMAKE_PREFIX_PATH "${${name}_BINARY_PREFIX}")
        if (_cmdep_bin_FIND_PACKAGE)
            find_package(${_cmdep_bin_FIND_PACKAGE} PATHS "${${name}_BINARY_PREFIX}" NO_DEFAULT_PATH)
        endif ()
    endif ()
endmacro()
