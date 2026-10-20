# Policies for cmake-dep's own code, so it behaves the same in a configure and
# in a bare `cmake -P` (include() keeps this from leaking into the includer).
cmake_policy(VERSION 3.18)

include(CmDepInstallDir)
include(CmDepBuildExternal)
include(CmDepTargetLinkLibrary)
include(CmDepFetch)
include(CmDepAddPackage)
include(CmDepBinary)
