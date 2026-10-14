#include <uv.h>

#include <cstdio>

int main()
{
  std::printf("built against libuv %s\n", uv_version_string());
  return 0;
}
