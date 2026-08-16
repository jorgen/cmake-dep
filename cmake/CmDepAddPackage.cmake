# CmDepAddPackage(<name> [CONFIG] [NO_SYSTEM_FIND] [INCLUDE_IN_ALL]
#                 [PACKAGE <pkg>] [SKIP_IF_TARGET <target>] [PUBLIC_INCLUDE <subdir>]
#                 [OPTIONS VAR=VALUE...] [SUBDIR_ARGS <args>...])
#
# Adds a fetched dependency with add_subdirectory. The subdirectory is added
# SYSTEM EXCLUDE_FROM_ALL by default: a dependency should be built because
# something links it, not because it happens to sit in the tree. That keeps a
# consumer from compiling and linking parts of a dependency it never uses.
#
# Two consequences of EXCLUDE_FROM_ALL worth knowing before reaching for
# INCLUDE_IN_ALL:
#   - A target nothing links is never built, so it is never compile-checked
#     either. A dependency whose targets are reached only indirectly (a tool
#     invoked by a custom command, a plugin loaded at runtime) needs an
#     explicit dependency edge or INCLUDE_IN_ALL.
#   - CMake also skips the subdirectory's install() rules. A consumer that
#     expects a bundled dependency to install its own headers or libraries
#     alongside the parent project needs INCLUDE_IN_ALL.
#
# INCLUDE_IN_ALL restores the pre-existing behaviour for one dependency.
# EXCLUDE_FROM_ALL is applied independently of SUBDIR_ARGS, so overriding the
# add_subdirectory arguments does not silently opt back into ALL.
function(CmDepAddPackage name)
    set(_options CONFIG NO_SYSTEM_FIND INCLUDE_IN_ALL)
    set(_one PACKAGE SKIP_IF_TARGET PUBLIC_INCLUDE)
    set(_multi OPTIONS SUBDIR_ARGS)
    cmake_parse_arguments(PARSE_ARGV 1 CMDEP_ADD "${_options}" "${_one}" "${_multi}")

    CmDepUseSystem(${name} _cmdep_use_system)

    if (_cmdep_use_system)
        if (NOT CMDEP_ADD_NO_SYSTEM_FIND)
            if (CMDEP_ADD_PACKAGE)
                set(_pkg "${CMDEP_ADD_PACKAGE}")
            else ()
                set(_pkg "${name}")
            endif ()
            if (CMDEP_ADD_CONFIG)
                find_package(${_pkg} CONFIG REQUIRED)
            else ()
                find_package(${_pkg} REQUIRED)
            endif ()
        endif ()
        return()
    endif ()

    if (CMDEP_ADD_SKIP_IF_TARGET AND TARGET ${CMDEP_ADD_SKIP_IF_TARGET})
        return()
    endif ()

    set(_forced "")
    foreach (_opt IN LISTS CMDEP_ADD_OPTIONS)
        string(FIND "${_opt}" "=" _eq)
        if (_eq EQUAL -1)
            message(FATAL_ERROR "CmDepAddPackage(${name}): OPTIONS entry '${_opt}' must be VAR=VALUE")
        endif ()
        string(SUBSTRING "${_opt}" 0 ${_eq} _k)
        math(EXPR _vstart "${_eq} + 1")
        string(SUBSTRING "${_opt}" ${_vstart} -1 _v)
        set(${_k} "${_v}" CACHE BOOL "" FORCE)
        list(APPEND _forced "${_k}")
    endforeach ()

    if (CMDEP_ADD_SUBDIR_ARGS)
        set(_subdir_args ${CMDEP_ADD_SUBDIR_ARGS})
    else ()
        set(_subdir_args SYSTEM)
    endif ()

    if (CMDEP_ADD_INCLUDE_IN_ALL)
        list(REMOVE_ITEM _subdir_args EXCLUDE_FROM_ALL)
    elseif (NOT "EXCLUDE_FROM_ALL" IN_LIST _subdir_args)
        list(APPEND _subdir_args EXCLUDE_FROM_ALL)
    endif ()

    add_subdirectory("${${name}_SOURCE_DIR}" ${_subdir_args})

    if (CMDEP_ADD_PUBLIC_INCLUDE)
        target_include_directories(${name} PUBLIC "${${name}_SOURCE_DIR}/${CMDEP_ADD_PUBLIC_INCLUDE}")
    endif ()

    foreach (_k IN LISTS _forced)
        unset(${_k} CACHE)
    endforeach ()
endfunction()
