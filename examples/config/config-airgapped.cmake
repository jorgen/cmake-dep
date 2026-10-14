# cmake-dep config for a machine without internet access.
#
# "direct" is deliberately absent: cmake-dep will only use these mirrors and
# will fail with a list of what it tried if an archive is missing, instead of
# reaching out to github.com & co.

set(CMDEP_MIRRORS "/mnt/share/cmake-dep-mirror,https://cmdep.lan.example.com")
