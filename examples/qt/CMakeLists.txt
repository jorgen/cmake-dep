# Example: a Qt Widgets application whose QtBase comes from cmake-dep as a
# binary package -- built once per machine (or downloaded from a team binary
# mirror), then shared by every checkout, worktree and build directory.
#
#   cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build build
#
# The first configure on a machine builds QtBase (expect 15-60 minutes);
# every later configure is instant. See docs/binary-packages.md.
cmake_minimum_required(VERSION 3.21)
project(cmdep_qt_example LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- cmake-dep -------------------------------------------------------------
include(FetchContent)
FetchContent_Declare(cmake-dep
    GIT_REPOSITORY https://github.com/jorgen/cmake-dep.git
    GIT_TAG main
)
if (EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/CmDepMain.cmake")
    set(FETCHCONTENT_SOURCE_DIR_CMAKE-DEP "${CMAKE_CURRENT_SOURCE_DIR}/../.." CACHE PATH "")
endif ()
FetchContent_MakeAvailable(cmake-dep)
list(APPEND CMAKE_MODULE_PATH "${cmake-dep_SOURCE_DIR}/cmake")
include(CmDepMain)

# --- QtBase as a binary package ---------------------------------------------
set(CMDEP_PACKAGES_FILE "${CMAKE_CURRENT_SOURCE_DIR}/cmake/packages.cmake")
CmDepFetch()

CmDepBinaryPackage(qtbase
    # Everything here is part of the build key: change an option, get a new build.
    CMAKE_ARGS
        -DQT_BUILD_TESTS=OFF
        -DQT_BUILD_EXAMPLES=OFF
        -DFEATURE_sql=OFF
    FIND_PACKAGE Qt6 REQUIRED COMPONENTS Core Gui Widgets)

# Qt6::moc etc. exist at configure time, so Qt's normal project setup works.
qt_standard_project_setup()

# --- application -------------------------------------------------------------
qt_add_executable(hello main.cpp)
target_link_libraries(hello PRIVATE Qt6::Widgets)

if (WIN32)
    # The Qt DLLs live in the cache; copy the ones we need next to the exe.
    add_custom_command(TARGET hello POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_RUNTIME_DLLS:hello> $<TARGET_FILE_DIR:hello>
        COMMAND_EXPAND_LISTS)
endif ()
