#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include <uv.h>

TEST_CASE("libuv reports a 1.x version")
{
  CHECK(uv_version() >= 0x010000);
  CHECK(uv_version() < 0x020000);
}
