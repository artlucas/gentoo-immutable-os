# 15 — Version Pinning and the Offline Archive

**Status: implemented 2026-08-27.** Scope is *which packages, at which versions* a build
produces, and keeping the inputs that produced them. Bit-identical output is a different goal
and stays where it is, in [08-roadmap.md](08-roadmap.md) item 6.

Supersedes the unmerged `plan/10-reproducible-builds.md` on branch
`worktree-plan-reproducible-builds` (slot 10 is [10-prune-audit.md](10-prune-audit.md)). That
document's analysis and its layer shapes are reused; three decisions differ and are marked
below.

## The claim that was not true

[02-build-pipeline.md](02-build-pipeline.md) opened its Principles with:

> **Pinned inputs:** stage3/container digest, Portage tree snapshot timestamp, and package set
> are all pinned in `config/build.conf` — two runs from the same config produce functionally
> identical images.

None of the three bound. Each failed silently, which is the failure mode this repo keeps
insisting on catching:

| Claimed pin | What actually happened |
|---|---|
| stage3 digest | `BUILDER_DIGEST=""`; `build.sh` only `warn`ed and used the floating tag. |
| tree snapshot | `10-fetch.sh` ran `emerge-webrsync --revert` inside a `docker run --rm` whose `/var/db/repos` was an **image layer, not a volume**. The revert died with the container. `builder/Dockerfile`'s `RUN emerge-webrsync` had no cache buster, so that layer never invalidated — the tree a build used was "whenever someone last rebuilt the builder image". |
| package set | `50-prune.sh` strips versions before diffing `expected-packages.txt`. It gated set membership only; `qtbase-6.11.1 → 6.11.2` passed without a word. |

And one that had already come true: **`SNAPSHOT_DATE="20260819"` was unreproducible before this
work started.** distfiles.gentoo.org keeps roughly nine days of snapshots; on 2026-08-27 the
mirror held `20260820`–`20260827`. A build from a clean builder image would have 404ed in stage
10. The pin expired and nothing noticed, which is the argument for this document in one line.

## Decisions

| | |
|---|---|
| Tree pin | **Commit SHA in `github.com/gentoo-mirror/gentoo`.** *(plan/10 chose a self-hosted tarball; rejected here because it means owning a host, and because the archive below makes the transport irrelevant anyway.)* |
| Enforcement | Constrain, then verify. The lock feeds the resolver *and* the result is diffed afterwards. |
| Scope | Image closure, builder closure, **and the preinstalled Flatpaks.** *(plan/10 did not cover Flatpaks; they are 2.7 GB of shipped bytes.)* |
| Durability | **Vendor everything.** A release archive that rebuilds the image with `--network none`. *(New; it is what turns plan/10's "capture the snapshot before the window closes" race into a non-issue.)* |

### The tree commit

```
TREE_REPO="https://github.com/gentoo-mirror/gentoo"
TREE_COMMIT="5b5d4f9a3857f639f2f7531630e7bb767c99b0f1"   # 2026-08-20 00:30:52 UTC
SNAPSHOT_DATE="20260820"                                  # asserted against timestamp.chk
```

**The SHA is the mirror's, not the development repo's.** A synced tree's
`metadata/timestamp.commit` names a commit in `gentoo.git`, whose SHAs the rsync mirror does not
share. Reading it off the tree and pasting it here produces a commit that does not exist.

This is the newest mirror commit at or before the `20260820` snapshot the builder image was
holding — the tree 0.3.0 was really built against. Mirror commits fall at `00:30:52` and
`01:45:59`, so nothing lands on the snapshot's `00:45:00` and byte-equality with the tarball is
not available from git. Measured rather than assumed: `compare/5b5d4f9…71e558b` spans 43 commits
and 96 files, touching 18 packages, of which the closure contains three
(`sys-kernel/gentoo-kernel-bin`, `virtual/dist-kernel`, `dev-python/vcs-versioning`) and every
change to them is the *addition* of a newer version the lock pins away from. Confirmed directly:
**all 655 atoms of `image.lock` and all 495 of `builder.lock` are present at this commit.**

**Transport is a codeload tarball, not `git clone`.** The stage3 has no git, and there is no
ebuild tree to emerge one from until the fetch completes — the ordering is circular. codeload
resolves the SHA to exactly that commit's tree, so the pin is still the commit. Measured at 6.7
seconds for a 33k-entry `metadata/md5-cache`, so no `egencache` pass is needed either.
`git fetch --depth=1 origin <sha>` is the equivalent transport if git is ever present.

No sha256 of the archive is recorded: GitHub's tarball compression is not guaranteed stable over
time. Verification is by content — `metadata/timestamp.chk` must parse to `SNAPSHOT_DATE`, and
`metadata/md5-cache` must exist.

## Layer 0 — making the pins bind

- `build.sh` mounts a fourth named volume `${DISTRO_ID}-tree` at `/var/db/repos`. The **parent**,
  not `…/gentoo`, so stage 20's `make.profile` symlink and the generated `repos.conf`
  `location = /var/db/repos/gentoo` both keep working. Docker seeds an empty named volume from
  the image layer, which is why the marker below is not optional.
- An empty `BUILDER_DIGEST` is now a hard `die`, escapable with `ALLOW_UNPINNED=1`. A warning
  printed on every build is a warning nobody reads. The escape drops `out/state/unpinned-build`,
  and **stage 80 refuses to assemble a release when it is present**.
- The Docker build context moved from `builder/` to the repo root (`-f builder/Dockerfile`), with
  a `.dockerignore`, because the Dockerfile now `COPY`s a lock.

## Layer 1 — the tree pin

`builder/Dockerfile` names `ARG TREE_COMMIT` immediately above the fetch, which is what finally
gives that layer a cache buster. `10-fetch.sh` reconciles the volume against the pin on every
run: marker matches → skip (measured: 1.6 s); otherwise repopulate.

**The ordering inside the fetch is load-bearing** and is the one failure that would survive every
other assertion here: unpack to a temp dir, validate `md5-cache` and `timestamp.chk`, `mv` into
place, and write `.tree-commit` **last**. Writing the marker before the tree is known good turns
a half-finished download into a tree permanently marked correct, which `tree_assert` would then
agree with forever.

Stages 20 and 30 re-assert the pin before resolving anything — each stage is its own container,
so this cannot be done once.

## Layer 2 — the version locks

| File | Covers | Constrains | Verified at | Size |
|---|---|---|---|---|
| `config/portage/lock/image.lock` | pre-prune `--root=$TARGET` closure | stage 30 | end of stage 30 | 655 atoms |
| `config/portage/lock/builder.lock` | the builder's own `/` closure | the Dockerfile | stage 10 | 495 atoms |

Sorted `=cat/pkg-ver` atoms, **generated, never authored** — the rule `expected-packages.txt`
already states. Each carries a header recording `TREE_COMMIT`, `SNAPSHOT_DATE`, `PROFILE`,
`PORTAGE_CONFIG_HASH` and the four `INCLUDE_*` / `CONSOLE_ONLY` switches.

Stage 30 emerges `@locked-image` **in place of** the loose sets. The lock is the full closure —
every transitive dependency named at an exact version — so the resolver has no freedom left. The
loose sets in `config/portage/sets/` stay: they are the request a relock re-resolves from.

Three guards, in the order they fire:

1. **Header hash vs current** (stage 20). The locks cannot be part of `portage_config_hash` —
   that is a cycle, since the hash is recorded *in* the lock — so the recorded value is asserted
   one-way instead. Catches "package.use changed and the lock did not", which would otherwise
   build an image whose flags and whose versions came from different configs.
2. **Every locked atom exists in the pinned tree** (stage 20), by checking
   `metadata/md5-cache/<category>/<pkg>-<ver>`. A file-existence sweep over 33k entries, so 655
   atoms cost milliseconds, and it reports *every* unbuildable pin at once. Left to emerge, the
   same problem arrives one atom at a time, minutes into a run.
3. **Bidirectional VDB-vs-lock diff** (end of stage 30), reporting added packages, removed
   packages and version changes as three separate sections. The reverse direction is the
   load-bearing half: keeping the locks out of `portage_config_hash` means a lock-only change no
   longer trips the stale-target guard, whose job was to catch a change that should *remove* a
   package. `--changed-use` upgrades and never removes, so that case is caught here instead.

### Two bugs this surfaced

**`portage_config_hash` was path-dependent.** It fed absolute paths to `sha256sum`, which prints
the filename beside the digest — so the host computed one hash and the container another for one
identical config. Invisible while the value only ever travelled container-to-container (stage 20
writes `.inputs-hash`, stage 30 reads it); a live bug the moment a committed file records it.
Now computed from paths relative to `$REPO`.

**Lock ordering was locale-dependent.** `sort` collates differently under `en_US.UTF-8` than
under `C`, so the same closure written on two machines came out in two orders and diffed against
itself. Every sort that touches a lock is now `LC_ALL=C`.

Both are asserted in `tests/test-pin-policy.sh`, because both were silent.

### Non-goal, stated deliberately

**The lock pins versions, not USE flags.** Two builds with different `package.use/image` but
identical versions both satisfy it. `PORTAGE_CONFIG_HASH` in the header and in provenance is
what pins the flags. `/cache/binpkgs/Packages` already records full `USE` per package if this is
ever wanted; that is a lock-format change, not a tweak.

### `expected-packages.txt` keeps its job

The lock pins versions *upstream* of the prune; `expected-packages.txt` gates the set the prune
*leaves behind*. Since the shipped set is a subset of a version-locked closure, a
version-stripped gate downstream is entirely sufficient — every version that can reach it has
already been fixed. `tests/test-pin-policy.sh` asserts that subset relation offline, so a
mismatch surfaces before a build rather than at stage 50 after one. No churn through
[03-package-set.md](03-package-set.md), [06-pruning.md](06-pruning.md), `package.mask/image` or
`package.use/image`, all of which name it.

## Layer 3 — the builder toolchain

`dracut`, `systemd`/`ukify` and `erofs-utils` build the shipped initrd, UKI and root filesystem,
so the builder's own versions are image inputs. The Dockerfile keeps its fifteen explicit atoms —
as `/etc/portage/sets/builder-request`, with all their reasoning — and emerges `@locked-builder`
instead. The request is the statement of intent a relock re-resolves from; the lock is what is
actually installed.

Stage 10 asserts the builder's VDB matches `builder.lock`. Degradation is self-healing: if the
binhost has dropped a locked version, Portage compiles it from the pinned tree — slower, still
correct. **The symptom is a builder rebuild that suddenly takes an hour**, which is precisely the
silent-slow-build failure `builder/Dockerfile` already carries two assertions about.

One accepted divergence, listed in `tests/test-pin-policy.sh` rather than tolerated silently:
`sys-apps/portage` is `3.0.81.2` on the builder and `3.0.81.3` in the image. The builder's copy
comes from the stage3 and is never re-emerged; the target resolves the tree's best. It ships in
neither — stage 50 unmerges it.

## Layer 4 — selective upgrade: the patch-release workflow

`scripts/relock.sh`. This is what the locks are *for*: not "nothing ever moves" but "things move
when they should, one reviewable diff at a time".

```
scripts/relock.sh --security          # GLSA-driven, least-change — the normal path
scripts/relock.sh dev-libs/openssl …  # release exactly these atoms
scripts/relock.sh --all               # re-resolve everything against the current tree
scripts/relock.sh --builder | --flatpak
```

**The mechanism, in one sentence:** write the set as the lock *minus* the atoms being released,
*plus* their names unversioned. Everything still named at an exact version cannot move; the
released ones float to the best the pinned tree offers. Atoms the tree no longer carries are
dropped too, named or not — keeping them would fail the emerge on exactly the pins the run exists
to replace.

`--security` uses `glsa-check`, which ships with `sys-apps/portage`; the GLSA database (3,836
entries) is in the tree, so this works offline. Its default solver is
`getMinUpgrade(minimize=True)` — a least-change upgrade, which is the question a patch release
asks. Package names are read from `-l`, whose one-line-per-GLSA format is far steadier to parse
than `-p`'s prose.

Output follows the flow `expected-packages.txt` already establishes: write
`out/reports/image.lock.generated` and `out/reports/lock.diff`, then stop. Nothing is committed
for you.

A patch release is therefore: bump `TREE_COMMIT` → `relock.sh --security` → review a three-line
diff → commit → bump `VERSION` → build → vendor. Everything not in that diff still carries the
version the previous release shipped.

## Layer 5 — the Flatpak lock

`config/flatpak/apps.lock`, `<ref> <commit>` lines. **18 refs: 5 apps and 13 runtimes**, and the
runtimes are the point — `org.freedesktop.Platform`, `org.kde.Platform` and the `.Locale`
extensions are most of the 2.7 GB of `/var/lib/flatpak` the image ships. Pinning the apps alone
would look complete and leave nearly all the bytes floating.

Stage 40 installs, deploys each locked commit with `flatpak update --commit=`, then reads back
`flatpak list --columns=ref,active` and asserts. The readback is the point: `--commit` on an
already-current ref exits 0 saying "Nothing to do", which is indistinguishable from success.

`FLATPAK_PREINSTALL_MODE="firstboot"` cannot be pinned by construction — the install happens on
the device, months later. The lock applies to `build` mode.

Flathub garbage-collects old commits on a schedule shorter and less documented than Gentoo's.
This is the least durable pin in the build, and Layer 7 is what makes an old release rebuildable
after Flathub has moved on.

## Layer 6 — provenance

`80-release.sh` writes `${DISTRO_ID}_<VERSION>.provenance.txt` into the channel dir **before**
`SHA256SUMS` is computed, so it inherits the existing detached signature for free: version,
tree repo and commit, snapshot date, builder digest, profile, Portage version,
`portage_config_hash`, the `INCLUDE_*` switches, and the sha256 of each lock. Given a release you
can reconstruct its inputs without the build host.

## Layer 7 — the vendored archive

A pin says *which* inputs; the archive keeps them. Gentoo removes old ebuilds routinely and
Flathub garbage-collects, so without this a pin only buys a shrinking window.

`scripts/stages/90-vendor.sh`, **no-op unless `VENDOR=1`** (`build.sh --vendor`) — at 13-14 GB
this is a release artifact, not something to produce on every run. Sizes are measured from the
live volumes, not estimated:

```
out/vendor/immos-<VERSION>/
  MANIFEST.sha256[.gpg]    every file below, signed with the release key
  provenance.txt           locks/{image,builder,apps}.lock   build.conf
  builder-image.tar.zst    7.8 GB -> ~3 GB   (carries the pinned tree)
  stage3-base.tar.zst      ~600 MB
  tree-<commit>.tar.zst    708 MB -> ~130 MB
  distfiles/               7.3 GB, 760 files
  binpkgs/                 3.0 GB, 664 packages   (VENDOR_PROFILE=full only)
  flatpak/                 ~2.7 GB OSTree repo at the locked commits
```

`stage3-base.tar.zst` and the tree tarball are redundant with the builder image, which contains
both. They are kept anyway, for ~700 MB, because they let the builder be *reconstructed and
audited* rather than trusted as an opaque 3 GB blob.

**Completing the distfiles is the part that must not be skipped.** `/cache/distfiles` holds only
what was actually built from source; anything merged from a binpkg never fetched its sources, so
the cache is *not* known to cover the closure. Stage 90 runs an explicit `emerge --fetchonly
--usepkg=n` over both locks, against a **fresh empty root**.

Both halves of that are load-bearing. `--usepkg=n` because a binary merge never looks at
`SRC_URI`, which is exactly how the cache came to be incomplete. And a fresh empty root rather
than `--emptytree`, which is the obvious way to say "consider everything" and is *not*
equivalent: `--emptytree` re-resolves DEPEND for packages that are merely installed, and against
this config that fails outright —

```
The following USE changes are necessary to proceed:
>=dev-qt/qttools-6.11.1 linguist
```

reached via `kde-frameworks/kcoreaddons` ← `kde-apps/baloo-widgets` ←
`dolphin[semantic-desktop]`, because `package.use/image` sets `-linguist` (its comment claims
nothing in the tree asks for it; that claim is false under full DEPEND re-resolution). An empty
root asks the question a clean rebuild actually asks — "install all of this from nothing" —
resolves cleanly, and yields exactly the distfiles a clean rebuild needs. Measured: `--emptytree`
fails, the empty root resolves 1,103 packages with no USE-change or conflict errors.

Flatpaks are exported with `flatpak create-usb` through a bind mount, so the 2.7 GB lands in the
archive directly rather than being written inside the target and copied out. An offline stage 40
reads them back with `--sideload-repo`; the remote stays configured, because sideloading replaces
the transport, not the trust.

### Consuming it

```
build.sh --offline --vendor-dir out/vendor/immos-<ver>
```

- **No `docker build` at all.** It needs a network, and reconstructing the builder offline would
  need the binhost's ~495 binary packages, which the builder image does **not** retain — its
  `/var/cache/binpkgs` is 4 KB, because portage consumes and drops them. The archived image is
  both the reliable path and the honest one: it is the exact builder that produced the release.
- Stage 10 seeds `/cache/distfiles` and `/cache/binpkgs` and restores the tree from the archive.
- **Every stage runs with `--network none`.** That is the enforcement, not a nicety: a build that
  can reach the network cannot prove it did not use it.

Portage needs no offline flag — with distfiles present and Manifest checksums matching it never
attempts a fetch, and the target has no binhost by design.

## Testing

`tests/test-pin-policy.sh` (T0, offline, 57 assertions, modelled on `test-binpkg-policy.sh`):
digest and commit shape, lock shape/sorting/headers, both `portage_config_hash` exclusions
asserted *behaviourally* as well as by grep, path-independence of that hash, the cross-lock
version agreement with its one documented exception, `expected-packages.txt` ⊆ version-stripped
`image.lock`, apps.lock format and runtime coverage, and that every stage actually consumes what
it claims to. `tests/test-build-dryrun.sh` covers the tree volume, the context move, the build
args, and that `--offline` emits `--network none` and no `docker build`.

The acceptance test for Layer 7 is the offline rebuild itself, and it has **not been run yet**:

```
docker volume rm -f immos-work immos-cache immos-tree
docker image rm immos-builder gentoo/stage3
scripts/build.sh --offline --vendor-dir out/vendor/immos-<ver>
```

**An archive that has not had an offline rebuild run against it is not known to work.** Stage 90
says so on completion, deliberately: everything it writes is a plausible archive, and only a
rebuild proves it is a complete one. A missing distfile hides in that gap until the year you need
it.

## What is verified, and what is not

Verified live on 2026-08-27:

- the codeload fetch, its assertions, and `timestamp.chk` parsing to `SNAPSHOT_DATE` (6.7 s)
- stage 10 populating a fresh tree volume, and skipping on a second run (1.6 s), with no leftover
  temp directory
- stage 10's builder-closure check against `builder.lock` (495 atoms, clean)
- all 1,150 locked atoms present in the pinned tree
- stage 20's three lock guards, including a real catch: the first `image.lock` seeded from
  `out/reports/` was rejected because those reports predate the plymouth removal
- `@base @hardware @desktop` resolving against the pinned tree to 655 target-bound packages
- stage 90's distfile-fetch resolution: 1,103 packages, clean
- the full offline suite (58 new assertions in `test-pin-policy.sh`)

Not yet exercised: a complete locked build (stages 30-80), `relock.sh` against a real GLSA hit,
the Flatpak `--commit` deploy and its readback, stage 90, and the offline rebuild. See
[07-testing.md](07-testing.md).

Two notes for whoever runs the first locked build.

**`out/reports/` is stale relative to `main`** — it describes a build that still had plymouth,
which is how the first attempt at seeding `image.lock` went wrong. The committed lock was
resolved fresh against the pinned tree instead, and differs from those reports by exactly that
one package. Do not seed a lock from `out/reports/` again; let stage 30 generate it.

**`dev-qt/qttools[-linguist]` is worth a second look**, though nothing here is blocked on it.
The comment in `package.use/image` says no package in the pinned tree asks for
`qttools[linguist]`, and full DEPEND re-resolution disagrees (see the stage 90 note above). The
three code paths that matter — stage 30's emerge, stage 90's fetch, and a from-scratch
resolution — all resolve cleanly, so this is a stale comment rather than a broken build. It is
recorded because the next person to reach for `--emptytree` will rediscover it the hard way.
