# cmake-dep user configuration -- annotated example.
#
# Install as:  ~/.config/cmake-dep/config.cmake
#              (%APPDATA%\cmake-dep\config.cmake on Windows,
#               or anywhere, pointed to by the CMDEP_CONFIG environment variable)
#
# Plain CMake, read once per configure. Use set() without CACHE.
# -D variables and environment variables of the same name take precedence, so
# anything here can be overridden per build.

# Ordered list of sources. "direct" = the URL in the project's packages file.
# Separate with "," (or ";"). The first source that has the archive wins; a
# source that is down is skipped for the rest of that configure.
set(CMDEP_MIRRORS "https://cmdep.lan.example.com,direct")

# Where extracted sources and the archive store live (default ~/.cache/cmake-dep).
# Put it on a big/fast disk if your home directory is small.
# set(CMDEP_DIR "/data/cmake-dep-cache")

# Keep downloaded archives in <CMDEP_DIR>/archives (default ON). Lets a damaged
# source tree be rebuilt offline, and makes the archive store rsync-able into a mirror.
# set(CMDEP_KEEP_ARCHIVES ON)

# Seconds of no progress before a mirror request is abandoned (default 10).
# set(CMDEP_MIRROR_TIMEOUT 10)

# Credentials for the mirror: prefer ~/.netrc or the CMDEP_MIRROR_HTTPHEADER
# environment variable over writing a secret into this file.
# set(CMDEP_MIRROR_HTTPHEADER "Authorization: Bearer <token>")
