cmake_minimum_required(VERSION 3.18)
project(cmake-dep LANGUAGES NONE)

install(
    DIRECTORY cmake/
    DESTINATION share/cmake-dep/cmake
)
install(
    FILES cmake-dep-config.cmake
    DESTINATION share/cmake-dep
)
