# QtBase source archive. Like every cmake-dep package it is pinned by hash.
#
# Fill in the hash before first use: download the archive once and run
#   cmake -E sha256sum qtbase-everywhere-src-6.8.1.tar.xz
# and compare it with the checksum Qt publishes next to the archive on
# download.qt.io. (With the placeholder below the configure fails with a hash
# mismatch that shows the downloaded file's hash -- don't just copy that: it
# trusts whatever you happened to download.)
CmDepFetchPackage(qtbase v6.8.1
    https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtbase-everywhere-src-6.8.1.tar.xz
    SHA256=0000000000000000000000000000000000000000000000000000000000000000
    LAZY)

# Alternatively pin QtBase straight from its git repository -- no archive hash to
# look up, git verifies the commit -- with:
#   cmdep add qtbase 6.8.1 https://github.com/qt/qtbase.git --git v6.8.1
# which writes a CmDepFetchGit(...) line like the one below. LAZY means the
# source is only fetched if Qt actually has to be built here: a machine that
# gets the binary package from a mirror never downloads Qt's sources.
#
# CmDepFetchGit(qtbase 6.8.1
#     https://github.com/qt/qtbase.git
#     0db4321f2f13c6870283f3fcc0f1a462fd7cf663  # v6.8.1
#     SHA256=<printed by cmdep add>
#     LAZY)
