# Dependencies of the example project. Name, version, URL, and the archive's
# hash -- the hash is what makes mirrors and the shared cache safe.
#
# To add one: download the archive once, `cmake -E sha256sum <file>`, add a line.

CmDepFetchPackage(libuv v1.51.0
    https://github.com/libuv/libuv/archive/refs/tags/v1.51.0.tar.gz
    SHA256=27e55cf7083913bfb6826ca78cde9de7647cded648d35f24163f2d31bb9f51cd)

CmDepFetchPackage(doctest v2.4.12
    https://github.com/doctest/doctest/archive/refs/tags/v2.4.12.tar.gz
    SHA256=73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70)
