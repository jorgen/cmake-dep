#!/usr/bin/env sh
# Populate one cmake-dep mirror from the packages files of several projects.
#
#   populate-mirror.sh <mirror> <packages-file>...
#
#   <mirror>  directory, file:// URL, or http(s):// URL that accepts PUT
#
# Example:
#   ./populate-mirror.sh /srv/cmake-dep-mirror \
#       ~/src/vio/CMake/3rdPartyPackages.cmake \
#       ~/src/structify/CMake/3rdPartyPackages.cmake
#
# Archives already in your local cache (~/.cache/cmake-dep/archives) are copied
# from there; the rest are downloaded from CMDEP_MIRRORS (default: upstream).
# For an HTTP mirror, export CMDEP_MIRROR_HTTPHEADER or use ~/.netrc for credentials.
set -eu

if [ "$#" -lt 2 ]; then
    sed -n '2,15p' "$0"
    exit 1
fi

CMAKE_DEP_DIR=${CMAKE_DEP_DIR:-"$(cd "$(dirname "$0")/../.." && pwd)"}
mirror=$1
shift

for packages in "$@"; do
    echo "==> $packages"
    cmake -DCMDEP_PACKAGES_FILE="$packages" \
          -DCMDEP_MIRROR_OUT="$mirror" \
          -P "$CMAKE_DEP_DIR/cmake/CmDepMirror.cmake"
done
