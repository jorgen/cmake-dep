get_filename_component(_cmake_dep_dir "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)

# Support both installed layout (share/cmake-dep/) and source layout (repo root)
if(EXISTS "${_cmake_dep_dir}/cmake/CmDepMain.cmake")
    list(APPEND CMAKE_MODULE_PATH "${_cmake_dep_dir}/cmake")
elseif(EXISTS "${_cmake_dep_dir}/share/cmake-dep/cmake/CmDepMain.cmake")
    list(APPEND CMAKE_MODULE_PATH "${_cmake_dep_dir}/share/cmake-dep/cmake")
endif()
