cmake_minimum_required(VERSION 3.18)

# Only define a project and install rules when built standalone. When consumed
# via FetchContent_MakeAvailable (which add_subdirectory's this tree), skip the
# project() call so cmake-dep never touches the consumer's PROJECT_NAME (the
# knob prefix is derived from it).
if (CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR)
    project(cmake-dep LANGUAGES NONE)

    install(
        DIRECTORY cmake/
        DESTINATION share/cmake-dep/cmake
    )
    install(
        FILES cmake-dep-config.cmake
        DESTINATION share/cmake-dep
    )
endif ()
