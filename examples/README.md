# Examples

| Directory | What's in it |
|---|---|
| [`project/`](project) | A small working project (libuv + doctest) using `CmDepFetch` and `CmDepAddPackage` |
| [`config/`](config) | User config files: [standard](config/config.cmake) (annotated), [air-gapped](config/config-airgapped.cmake), [CI writer](config/config-ci-writer.cmake) |
| [`mirror-servers/`](mirror-servers) | Serving a mirror: file share, nginx (with authenticated PUT), Artifactory, Nexus, S3 |
| [`ci/`](ci) | GitHub Actions: [caching the archive store](ci/github-actions.yml), [keeping a mirror in sync](ci/populate-mirror.yml) |
| [`scripts/`](scripts) | [`populate-mirror.sh`](scripts/populate-mirror.sh): one mirror from several projects' packages files |

Background: [docs/caching-and-mirrors.md](../docs/caching-and-mirrors.md).

## A typical team setup

1. **Stand up a mirror.** An nginx box ([`nginx.conf`](mirror-servers/nginx.conf)) or a file share.
2. **Seed it** from a machine that has already built your projects:
   `rsync -a ~/.cache/cmake-dep/archives/ mirror:/srv/cmake-dep-mirror/`
3. **Point developers at it.** Drop [`config/config.cmake`](config/config.cmake) into
   `~/.config/cmake-dep/` (or set `CMDEP_MIRRORS` in the environment).
4. **Keep it filled.** Either give CI push rights ([`config-ci-writer.cmake`](config/config-ci-writer.cmake))
   or run [`ci/populate-mirror.yml`](ci/populate-mirror.yml) whenever a packages file changes.
