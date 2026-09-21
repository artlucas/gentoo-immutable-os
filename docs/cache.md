# Build cache

The first build compiles every package the image ships. Every later build runs against three persistent volumes that make that cost one-time: binary packages, source tarballs, and the pinned ebuild tree.

## What is cached

| Location | Content | Written by |
|---|---|---|
| `/cache/binpkgs` (portage `PKGDIR`) | Binary packages this pipeline compiled (`FEATURES=buildpkg` in `config/portage/make.conf.in`) | Stage 30, relock |
| `/cache/distfiles` (portage `DISTDIR`) | Source tarballs for both roots — target packages and builder-root dependencies | Stages 10, 20, 30; relock |
| `/cache/distfiles/gentoo-<date>.tar.xz` (+ `.gpgsig`, `.md5sum`) | The pinned tree snapshot with upstream's signature, parked so it survives the stage that fetched it | Stage 10 |
| `/var/db/repos` (tree volume) | The pinned ebuild tree and the `.tree-pin` marker | Stage 10 |

The volumes are named `immos-cache` and `immos-tree`; the work volume `immos-work` is not a cache — it holds the target rootfs and config root.

## Reuse rules

- Target merges run with `--usepkg` and without `getbinpkg`: a package present in `/cache/binpkgs` merges in seconds; a missing one compiles. The target never consumes `PORTAGE_BINHOST` — everything the image ships was compiled by this pipeline or reused from its own earlier builds.
- Binhost-sourced packages never enter the cache: stage 20 deletes any signed `.gpkg` in `/cache/binpkgs` (provenance is readable off the package — the Gentoo binhost signs, this pipeline does not).
- Packages from `config/portage/overlay/` are excluded from binary reuse and recompiled from the checkout on every stage-30 run.
- One `DISTDIR` serves both the builder's own `/` and the target, and anything stranded in a container-local distfiles directory is swept across at the end of each stage. Both exist so an offline rebuild has every source it needs.
- Profiles share the cache: every profile emerges from the same config root and `package.use`, so packages two profiles share resolve to the same binary package, and the second profile's build mostly merges. Per-profile USE changes defeat this — do not introduce them.

## Invalidation

| Condition | Detection | Recovery |
|---|---|---|
| `config/portage` or `config/build.conf` changed, stage 20 not re-run | Stage 30 guard: `portage_config_hash()` vs the config root's recorded `.inputs-hash` | `bash scripts/build.sh --only 20`, then continue |
| Target root carries package membership the current config would drop | Stage 30 guard: `target_closure_hash()` vs `/work/target-config-hash*` | `docker volume rm -f immos-work`, then rebuild; the binary cache survives, so the re-merge mostly reinstalls |
| Tree pin moved | `tree_assert()` in every depgraph stage and in `relock.sh`, against `.tree-pin` | `bash scripts/build.sh --only 10` repopulates the tree volume |
| Builder image stale | Docker layer cache: keyed on the base digest, `BINHOST_URI`, the `SNAPSHOT_DATE` build argument, and the copied `builder.lock` | Rebuilt automatically on the next `build.sh`; edits under `config/portage` outside `builder.lock` never trigger it |
| Snapshot no longer on distfiles.gentoo.org (~9 days retention) | webrsync fails in stage 10 | Restore from a vendored archive (below); a moved pin must be captured while live |

## `--clean`

```sh
bash scripts/build.sh --clean
```

Removes the `immos-work` volume and every `out/state*` stamp directory, for every profile, and keeps `immos-cache`. Use it when per-profile state is suspect but the compiled packages are not. To discard everything, remove the remaining volumes explicitly:

```sh
docker volume rm -f immos-cache immos-tree
```

The next build then recompiles from scratch.

## Offline rebuilds

Produce the archive as part of a release build:

```sh
bash scripts/build.sh --vendor
```

Stage 90 archives into `out/vendor/immos-<version>/`: the signed snapshot tarball, the complete distfiles closure, `/cache/binpkgs`, the Flatpak store, and the builder image tarballs (saved host-side by `build.sh`). The archive is 13–14 GB.

Rebuild from it with no network at all:

```sh
bash scripts/build.sh --offline --vendor-dir out/vendor/immos-0.3.0
```

Offline semantics:

- `--offline` requires `--vendor-dir` and is an assertion, not a hint: every stage runs with `--network none`, so a build that quietly reached the network cannot happen.
- The builder image is loaded from the archived tarball instead of built — it is the exact builder that produced the release.
- Stage 10 seeds `/cache/distfiles` and `/cache/binpkgs` from the archive.
- `--with-test-dc` and `--with-test-api` are incompatible with `--offline` (their fixtures need a network to build); the corresponding stage-70 tests skip.
