# Deprecated: prefer CmDepBinaryPackage (docs/binary-packages.md), which builds
# the dependency once per machine instead of once per build tree, finds it at
# configure time (real imported targets, no CMDEP_LOCATION_* properties), and
# can share it through binary mirrors. This module keeps working unchanged;
# see docs/build-external.md for its documentation and a migration guide.

# Policies for cmake-dep's own code, so it behaves the same in a configure and
# in a bare `cmake -P` (include() keeps this from leaking into the includer).
cmake_policy(VERSION 3.18)

function(CmDepInstallDir var name version)
	set(${var} "${PROJECT_BINARY_DIR}/${name}_${version}_install" PARENT_SCOPE)
endfunction()
