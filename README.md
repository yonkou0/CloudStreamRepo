# CloudStreamRepo

Combined **stable** CloudStream plugin repository, assembled from two sources:

| Source | What it is | Count |
|---|---|---|
| `raghav-master` (KSHITIJ8473) | Kotlin plugin **source code**, compiled against the pinned CloudStream API (see [Reproducible builds](#reproducible-builds-no-more-phantom-updates)) | 30 |
| `Desi-main` (Faisal0786) | Compiled `.cs3` **binaries** (upstream source no longer available), imported byte-identical and hash-verified | 6 |

**36 plugins total** — only plugins that pass validation are included.

## Included plugins

### Built from source (30, status = Ok)
AniChan · Anidap · AniKotoAnime · AnimeInWeb · AnimeWorldIndia · Animo · AniPM · AniSuge · AniWaves · DamiTVProvider · GoTaku · JustPlay · Kdesa · LIVETVProvider · Miruro · Multimovies · NetNaija · NetNaija-box · NineAnime · RaghavAnime · RaghavAnimeKitsu · RareAnimesIndia · ReAnime · ReplayZone · Senshi · StreamedPk · TheMoviesFlix · TorrentsV1 · TwoDHive · Xanime

### Imported binaries (6)
AniStream · Ctg Stream · MovieBox · OttSource · SDmovies · StreamHubOne

### Deliberately excluded
- `The Movie Flix.cs3` (Desi binary, v2) — superseded by the **source-built TheMoviesFlix (v22)**, which can actually be updated and fixed. Keeping both would install two entries for the same provider.

## Layout

```
CloudStreamRepo/
├── repo.json           # repository manifest (points at plugins.json)
├── plugins.json        # plugin index: 36 entries with verified sha256 hashes
├── builds/             # all 36 .cs3 packages served to CloudStream
├── tools/
│   ├── build-repo.ps1      # one-command build + assemble pipeline
│   ├── repo-config.json    # <- set your GitHub URLs here
│   └── imported-plugins.json  # metadata for the 6 imported Desi binaries
├── <30 module dirs>    # CloudStream plugin sources (Gradle project)
└── .github/workflows/build.yml  # CI: build + commit updated builds/
```

## Hosting setup (once)

1. Push this folder to a GitHub repository (branch `main`).
2. Edit `tools/repo-config.json` and replace `YOUR_GITHUB_USERNAME/CloudStreamRepo` with your real repo.
3. Run `pwsh tools/build-repo.ps1 -SkipBuild` to regenerate `plugins.json` / `repo.json` with your URLs, then commit.
4. In CloudStream add the repository:
   `https://raw.githubusercontent.com/YOU/CloudStreamRepo/main/repo.json`

## Building locally

Prerequisites: **JDK 17+**, **Android SDK** (platform 36, build-tools 36.x), network for Gradle dependencies.

```powershell
# Windows
powershell -File tools\build-repo.ps1
# Linux / macOS
pwsh -File tools/build-repo.ps1
```

This compiles every module (`gradlew make makePluginsJson`), copies the packages to
`builds/`, merges the imported binaries, and rewrites `plugins.json` + `repo.json`.
Use `-SkipBuild` to re-assemble without recompiling.

## Stability guarantees

- All 30 source modules must compile or the pipeline **fails** (no partial/broken releases).
- Imported binaries were checked for: valid zip, `manifest.json` present, `classes.dex` present, `fileSize` and `sha256` matching their originally published values.
- Assembly **fails hard** on a missing package file or duplicate `internalName`.
- `fileSize`/`fileHash` in `plugins.json` are always recomputed from the actual files, so clients can never get a hash mismatch.
- CI (`.github/workflows/build.yml`) rebuilds everything on push and commits only when outputs change (`[skip ci]` prevents loops).
- `tools/build-repo.ps1` reports which plugins produced a **different binary** and reminds you to bump `version`, because CloudStream re-downloads a plugin whenever its `fileHash` changes.

## Reproducible builds (no more phantom updates)

The CloudStream Gradle plugin resolves its API jar from

```
https://github.com/recloudstream/cloudstream/releases/download/pre-release/classes.jar
```

`pre-release` is a **moving tag**. CloudStream re-uploads that asset on every
pre-release build, so the same source compiled on two different days produced
different `classes.dex` debug metadata. Every affected `.cs3` got a new
`fileHash`, and **all users re-downloaded every plugin** for no functional
change. It was also non-reproducible: a clean CI runner downloaded the newest
jar while a developer machine reused its older cache.

Pinning a version does not help - only `pre-release` publishes `classes.jar`
(the `v4.8.0`/`v4.7.0`/... tags have no such asset), and the plugin ignores the
version string in `build.gradle.kts` anyway.

**The fix:** the exact jar we build against is vendored at
`local-repo/cloudstream-api/pre-release/classes.jar`, and `build.gradle.kts`
seeds the plugin's own cache with it before the plugin is applied. Its sha256 is
recorded in `tools/cloudstream-api.lock.json` and verified on every build, so a
partial or accidental replacement fails loudly instead of silently shipping 30
changed binaries.

Current pin: `4.7.0-PRE`, sha256 `4abf03265aac...`.

**To upgrade the CloudStream API deliberately:**

1. Download the new jar:
   `https://github.com/recloudstream/cloudstream/releases/download/pre-release/classes.jar`
2. Overwrite `local-repo/cloudstream-api/pre-release/classes.jar`
3. Update the `sha256` and `size` in `tools/cloudstream-api.lock.json`
4. Bump the `version` of every module you want users to re-download

Step 4 matters: without a version bump, CloudStream keeps serving users the
cached copy, so an API upgrade can appear to do nothing.

## Upstream health checks

These providers depend on third-party mirror sites that **rotate domains without
notice** (the NetMirror family has already gone `net52` → `net77` → a dead `net50`).
When a domain rots, every user of that provider gets an error and nothing in the
build fails. `tools/build-repo.ps1` therefore probes the live endpoints at the end of
every run and reports:

```
==> Upstream health: 6/6 healthy

Check                             Status Detail
-----                             ------ ------
OttSource / main search API       OK
OttSource / main detail API       OK
OttSource / PrimeVideo search API OK
OttSource / Hotstar search API    OK
OttSource / playlist API          OK
OttSource / ad-bypass host        OK
```

Status meanings:

| Status | Meaning |
|---|---|
| `OK` | Serving the expected content |
| `GATED` | Answered HTTP 200 but with an app-gate page instead of data |
| `BROKEN` | Responded, but the expected fields are missing (API shape changed) |
| `DEAD` | Wrong HTTP status, or a redirect to a host that no longer resolves |
| `UNREACHABLE` | DNS or connection failure |

The checks assert on the **response body**, not just the status code, because these
sites serve their app-gate page with HTTP 200 — a status-only check would report a
fully blocked provider as healthy.

Probes live in [`tools/domain-health.json`](tools/domain-health.json); add an entry
whenever a provider changes domain. Results are a **warning by default** so a
third-party outage never blocks a release:

```powershell
# default: warn but still publish
pwsh -File tools/build-repo.ps1

# offline / air-gapped
pwsh -File tools/build-repo.ps1 -SkipHealthCheck

# strict: fail the build if any upstream is unhealthy (useful in CI)
pwsh -File tools/build-repo.ps1 -FailOnUnhealthy
```

## Disclaimer

These extensions function similarly to a standard web browser by fetching video files
from the internet. No content is hosted by this repository or the CloudStream app;
all content is hosted by third-party websites. Users are solely responsible for
their usage and must comply with their local laws. This project is created strictly
for educational, research and development purposes.

## License

This repository is licensed under the **GNU General Public License v3.0** — see
[`LICENSE`](LICENSE) for the full text. The plugins in `builds/` are distributed as
compiled `.cs3` packages; the corresponding source for the 30 source-built modules is
included in this repository, as GPLv3 requires.

Provenance of the included plugins:

| Set | Count | Upstream author | Terms |
|---|---|---|---|
| Source-built modules | 30 | `raghav` / `KSHITIJ8473` / `csksy` | GNU GPLv3 (per upstream) |
| Imported binaries | 6 | `Faisal0786` | redistributed unmodified from upstream |

Note that CloudStream extensions are decompilable: the `.cs3` packages contain a
`classes.dex` that carries class and string names in the clear. Hiding the Kotlin
source therefore provides no meaningful protection against a determined reader, and
would conflict with the GPLv3 obligations that apply to the source-built modules.

Third-party API keys (for example the Firebase and TMDB keys in
`LIVETVProvider/build.gradle.kts` and `TorrentsV1/build.gradle.kts`) belong to their
respective owners and are used here only to call those public APIs.

