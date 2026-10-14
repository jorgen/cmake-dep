# Mirror server setups

A cmake-dep mirror is just files at `<base>/<algo>/<hex>`, so most things that can serve files work.
Everything served is hash-checked by the client, so the server doesn't need to be trusted. See
[docs/caching-and-mirrors.md](../../docs/caching-and-mirrors.md) for the full picture.

| Setup | Read | Write-back (`CMDEP_MIRROR_PUSH`) | Notes |
|---|---|---|---|
| File share (NFS/SMB) | ✓ | ✓ | Simplest. Use a path or `file://` URL |
| `python3 -m http.server` | ✓ | ✗ | Quick test server |
| nginx + WebDAV | ✓ | ✓ | [`nginx.conf`](nginx.conf) |
| Artifactory generic repo | ✓ | ✓ | Header auth |
| Nexus raw repo | ✓ | ✓ | Basic auth via netrc |
| S3 / GCS bucket | ✓ (public or via proxy) | ✗ (sync instead) | Populate with `aws s3 sync` |

## File share

```bash
# server: export /srv/cmake-dep-mirror; clients mount it, e.g. at /mnt/cmake-dep-mirror
export CMDEP_MIRRORS=/mnt/cmake-dep-mirror,direct
export CMDEP_MIRROR_PUSH=/mnt/cmake-dep-mirror     # optional: needs write access
```

Pushes are written to a temporary name and renamed, so readers never see partial files. On Windows,
use a mapped drive (`M:/cmake-dep-mirror`) or a UNC path written with forward slashes
(`//server/share/cmake-dep-mirror`).

## Quick test server

```bash
python3 -m http.server 8080 --directory /srv/cmake-dep-mirror
export CMDEP_MIRRORS=http://localhost:8080,direct
```

## nginx

See [`nginx.conf`](nginx.conf): anonymous reads, password-protected PUT.

## Artifactory (generic repository)

Create a *generic* local repository, e.g. `cmake-dep`:

```bash
export CMDEP_MIRRORS=https://artifactory.example.com/artifactory/cmake-dep,direct
export CMDEP_MIRROR_HTTPHEADER="Authorization: Bearer $ARTIFACTORY_TOKEN"
export CMDEP_MIRROR_PUSH=https://artifactory.example.com/artifactory/cmake-dep   # writers
```

## Nexus (raw hosted repository)

```bash
export CMDEP_MIRRORS=https://nexus.example.com/repository/cmake-dep,direct
export CMDEP_MIRROR_PUSH=https://nexus.example.com/repository/cmake-dep
# credentials in ~/.netrc:
#   machine nexus.example.com login deployer password <pw>
```

## S3 / GCS

Reads work over plain HTTPS if the bucket (or a CDN in front of it) allows anonymous GET:

```bash
export CMDEP_MIRRORS=https://my-bucket.s3.eu-north-1.amazonaws.com/cmake-dep,direct
```

cmake-dep can't sign S3 PUTs, so populate the bucket by syncing:

```bash
aws s3 sync ~/.cache/cmake-dep/archives/ s3://my-bucket/cmake-dep/
```

A private bucket returns 403, which cmake-dep treats as "not here" and moves on to the next source.
