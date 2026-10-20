# The `cmdep` command

`cmdep` is cmake-dep's command line. It is a thin wrapper (`bin/cmdep`, and `bin/cmdep.cmd` on
Windows) around a CMake script, so it needs nothing but CMake. It uses the same code, cache,
mirrors and settings as a configure.

```bash
# from a checkout of cmake-dep
export PATH="$PATH:/path/to/cmake-dep/bin"
# or after `cmake --install`: <prefix>/bin/cmdep
cmdep help
```

A different CMake can be selected with `CMAKE=/path/to/cmake cmdep …`. Run `cmdep` from your
project's root: that's where it looks for the packages file.

## Commands

### Dependencies

| Command | What it does |
|---|---|
| `cmdep add <name> <version> <url>` | Download `<url>`, hash it, keep it in the archive store, append `CmDepFetchPackage(...)` to the packages file (creating `cmdep-packages.cmake` if there is none). Fails if `<name>` is already declared |
| `cmdep add <name> <version> <repo> --git <ref>` | Resolve `<ref>` (tag, branch or commit) with `git ls-remote`, archive that commit, append a pinned `CmDepFetchGit(...)` |
| `cmdep hash <url-or-file> [--algo SHA512]` | Print `SHA256=<hex>` (or another algorithm) for an archive |
| `cmdep fetch` | Fetch everything in the packages file, plus the locked transitive packages, without a configure |
| `cmdep lock` | Resolve the dependency graph into `cmdep.lock` ([details](dependencies.md#the-lockfile)) |
| `cmdep lock --check` | Exit non-zero if `cmdep.lock` is missing or out of date |
| `cmdep update` | Same as `cmdep lock` |
| `cmdep tree` | Print the locked graph, with requests that were unified |

`add` hashes whatever it downloads. If the project publishes checksums, compare them: the pin is
only as good as the download it came from. (`--git` is different: git verifies the commit.)

### Mirrors and binaries

| Command | What it does |
|---|---|
| `cmdep mirror <dir-or-url>` | Copy every pinned archive (including locked transitive ones) into a mirror: a directory, `file://` URL, or HTTP(S) URL that accepts PUT |
| `cmdep push-binary <cache entry> <dir-or-url>` | Upload a binary package from `~/.cache/cmake-dep/bin/` to a binary mirror (signed if `CMDEP_BINARY_SIGNING_KEY` is set) |
| `cmdep keygen <file> [--principal <name>]` | Create an ed25519 signing key for binary packages, plus the `allowed_signers` line for clients |

### Cache

| Command | What it does |
|---|---|
| `cmdep status` | List cache entries (sources, binary packages, archives) with size and last use |
| `cmdep gc` | Remove entries unused for 90 days, abandoned temp dirs and stale incomplete entries |
| `cmdep gc --older-than 30d` | Different age limit (`s`, `m`, `h`, `d`, `w`) |
| `cmdep gc --max-size 20G` | Also evict least recently used entries until the cache fits (`K`, `M`, `G`, `T`) |
| `cmdep gc --dry-run` | Show what would be removed |
| `cmdep verify [--dry-run]` | Re-hash every stored archive (removing corrupt ones) and report incomplete entries |
| `cmdep cache-dir` | Print the cache directory |

`gc` never deletes an entry that a running configure holds the lock for. Archives used in the
last hour are kept even under `--max-size`. "Last used" is refreshed at most once a day when a
configure uses an entry. Deleting something a build tree still references only costs a re-fetch
(or rebuild) at its next configure.

## Global options

| Option | Meaning |
|---|---|
| `--packages <file>` | The packages file. Default: `$CMDEP_PACKAGES_FILE`, then the first of `cmdep-packages.cmake`, `CMake/3rdPartyPackages.cmake`, `cmake/3rdPartyPackages.cmake`, `cmake/packages.cmake`, `CMake/packages.cmake` in the current directory |
| `--cache-dir <dir>` | Cache directory (same as `CMDEP_DIR`) |
| `--project <prefix>` | Knob prefix, so `-D<PREFIX>_<DEP>_URL/_SHA256/_USE_SYSTEM…` apply |
| `-D<VAR>=<VALUE>` | Set any setting, e.g. `-DCMDEP_MIRRORS=…`, or an option your packages file tests |

Options take `--opt value` or `--opt=value`. All [settings](caching-and-mirrors.md#settings-reference)
can also come from the environment or `~/.config/cmake-dep/config.cmake`.

## Examples

```bash
# start a project
cmdep add libuv v1.51.0 https://github.com/libuv/libuv/archive/refs/tags/v1.51.0.tar.gz
cmdep add doctest v2.4.12 https://github.com/doctest/doctest/archive/refs/tags/v2.4.12.tar.gz
cmdep lock -DMYPROJ_BUILD_TESTS=ON

# CI
cmdep lock --check
cmdep fetch --project myproj -DCMDEP_MIRRORS=https://cmdep.lan,direct

# keep a team mirror filled from several projects
for p in ~/src/vio ~/src/structify; do (cd "$p" && cmdep mirror /srv/cmake-dep-mirror); done

# housekeeping
cmdep status
cmdep gc --older-than 60d --max-size 30G --dry-run
cmdep gc --older-than 60d --max-size 30G
```

## Without the wrapper

Every command is also a plain CMake script call:

```bash
cmake -P /path/to/cmake-dep/cmake/CmDepCli.cmake -- <command> [args]
```

The older single-purpose scripts still work: `CmDepFetchDependencies.cmake`, `CmDepMirror.cmake`,
`CmDepBinaryPush.cmake` and `CmDepCache.cmake` (see the comments at the top of each).
