# 10 — Reproducible Package Versions

**Status: designed, not implemented (2026-08-24).** Scope is *which packages and which versions* a
build produces. Bit-identical output is a different goal and stays where it is, in
[08-roadmap.md](08-roadmap.md) item 6.

## The claim that is not true yet

[02-build-pipeline.md](02-build-pipeline.md) opens its Principles with:

> **Pinned inputs:** stage3/container digest, Portage tree snapshot timestamp, and package set are
> all pinned in `config/build.conf` — two runs from the same config produce functionally identical
> images.

None of the three pins currently binds. Each fails silently, which is the failure mode this repo
keeps insisting on catching, so each is written out here in full.

| Claimed pin | What actually happens |
|---|---|
| stage3 / container digest | `BUILDER_DIGEST=""` in `config/build.conf`. `scripts/build.sh:108` only `warn`s and carries on with the floating `gentoo/stage3:amd64-systemd` tag. |
| Portage tree snapshot | `scripts/stages/10-fetch.sh:29-31` runs `emerge-webrsync --revert="$SNAPSHOT_DATE"` — inside a `docker run --rm` container whose `/var/db/repos/gentoo` is an **image layer, not a volume**. The revert is discarded when the container exits. Stages 20 and 30 resolve their depgraph against whatever tree the layer-cached `RUN emerge-webrsync` (`builder/Dockerfile:11`) happens to hold, and that layer has no cache buster, so it never invalidates. |
| package set | `config/portage/expected-packages.txt` is compared **after versions are stripped** — `scripts/stages/50-prune.sh:68` does `sed -E 's/-[0-9][^/]*$//'` before the diff. It gates set membership, and only set membership. A `dev-qt/qtbase-6.11.1 → 6.11.2` swap passes it without a word. |

So the pin most people would assume is load-bearing — the tree — is asserted in a container that
then throws the result away. The tree the build actually uses is "whenever someone last rebuilt
the builder image".

Two further gaps, both structural:

- **`SNAPSHOT_DATE` is not durable even in principle.** distfiles.gentoo.org keeps roughly nine
  days of snapshots. `config/build.conf` already admits this in a comment: an older pin 404s and
  stage 10 fails. A pin that expires is not a pin; it is a countdown.
- **Nothing about the build is published.** `scripts/stages/80-release.sh` emits the artifacts,
  `SHA256SUMS` and a detached signature. There is no record of the tree, the profile, the base
  image, or the resulting package versions. The only per-build metadata that ships is the version
  embedded in the filenames, and `/usr/share/${DISTRO_ID}/manifest.txt` inside the image, which
  nothing outside the image can read without mounting it.

## Decisions

| | |
|---|---|
| Guarantee | **Layered.** Pin the tree so a rebuild is identical by construction, *and* commit a version lock so a deliberate pin bump produces a reviewable diff rather than a silent wholesale move. |
| Enforcement | **Constrain, then verify.** The lock feeds the resolver so it cannot pick anything else, and the result is diffed afterwards anyway. |
| Tree transport | **Self-hosted tarball.** Capture the upstream snapshot once, host it, depend on nobody afterwards. |
| Scope | **Image *and* builder.** `dracut`, `systemd`/`ukify` and `erofs-utils` versions shape the shipped initrd, UKI and root image; leaving them floating leaves a real hole. |

## Facts this design rests on

Verified against the live builder image and the current upstream mirrors on 2026-08-24, because
each one decides a branch of the design:

- **`emerge-webrsync` can keep its snapshot.** `-k`/`--keep` retains the tarball in `DISTDIR`
  (`/usr/sbin/emerge-webrsync`, option table line 33, `DISTDIR` handling lines 66-69). `DISTDIR`
  here is `/cache/distfiles`, already a persistent named volume, so capturing costs nothing extra.
- **The snapshot is upstream-authenticated at capture time.** Upstream publishes
  `gentoo-YYYYMMDD.tar.xz` alongside `.gpgsig` and `.md5sum`, and webrsync verifies both
  (`check_file_digest`, `check_file_signature`) before unpacking.
- **The current pin is still capturable, but not for long.** `gentoo-20260819.tar.xz` is 47 MB and
  returns HTTP 200 today. The retention window closes around 2026-08-28. After that
  `SNAPSHOT_DATE="20260819"` is simply unreproducible and the pin has to move to a newer tree.
- **The binpkg cache already carries provenance nobody reads.** `/cache/binpkgs` (446 packages,
  1.5 GB) runs `FEATURES=binpkg-multi-instance buildpkg`, and its `Packages` index records
  `REPO_REVISIONS: {"gentoo": "0d72baa9…"}`, `PROFILE`, `ACCEPT_KEYWORDS` and the full `USE`
  string. The cache knows exactly which tree it was built against; the pipeline never asks.
- **`stamp_matches` is dead code.** Defined at `scripts/lib/common.sh:265`, called by nothing.
  Every stage writes `out/state/<stage>.done` and no stage reads one; `FORCE_STAGE` is likewise
  plumbed through `build.sh:99,102,127` and never read. Resume is entirely manual via `--from`.
  Noted because it looks like the caching layer this document needs and is not.

## Layer 0 — make the existing pins bind

Nothing below works until the tree survives a stage boundary.

**Persist the tree.** Mount a new named volume `${DISTRO_ID}-tree` at `/var/db/repos`, alongside
the existing `-work` and `-cache` mounts in `scripts/build.sh`. Mounting the *parent* directory
rather than `…/gentoo` keeps every existing path valid: `scripts/stages/20-builder-setup.sh:22`
symlinks `make.profile` into `/var/db/repos/gentoo/profiles/$PROFILE`, and the generated
`repos.conf` keeps `location = /var/db/repos/gentoo` (`20-builder-setup.sh:53`). Both roots — the
builder's own `/` and `--root=$TARGET` — then resolve against one pinned tree, which is what makes
the "image *and* builder" scope achievable at all rather than two separate problems.

**Fail on an unpinned base.** `BUILDER_DIGEST=""` becomes a hard `die`, not a `warn`, unless an
explicit escape (`ALLOW_UNPINNED=1`) is passed. Record the current digest of
`gentoo/stage3:amd64-systemd` in `config/build.conf` at the same time. A warning that is printed
on every single build is a warning nobody reads.

## Layer 1 — the tree pin, as a tarball we host

Two new keys in `config/build.conf`, next to the existing `SNAPSHOT_DATE`:

```
SNAPSHOT_URL="https://immos.trinora.software/snapshots"   # empty → fall back to upstream distfiles
SNAPSHOT_SHA256="…"                                       # of gentoo-<SNAPSHOT_DATE>.tar.xz
```

**Capture** — a new `scripts/capture-snapshot.sh`, run once per deliberate pin bump and
necessarily *inside* the nine-day window:

**Does:** runs `emerge-webrsync --revert="$SNAPSHOT_DATE" --keep` in a throwaway `gentoo/stage3`
container, verifies the `.gpgsig`, computes the sha256, leaves the tarball in `out/snapshots/`,
and prints the `SNAPSHOT_DATE` / `SNAPSHOT_SHA256` pair to paste into `config/build.conf`. The
operator uploads the tarball and its `.gpgsig` to `SNAPSHOT_URL`.

**Verify:** the printed sha256 matches the uploaded file; upstream's signature checks out before
anything is recorded.

It runs against the **stage3 base image, not `immos-builder`**. That is not incidental: the
builder image itself consumes the pin (below), so capturing from inside it would be circular — you
could never bootstrap a new pin without an image already built against one.

**Consume**, in two places that must agree with each other:

- `builder/Dockerfile` replaces `RUN emerge-webrsync` with a pinned fetch — `ARG SNAPSHOT_DATE`,
  `ARG SNAPSHOT_SHA256`, then curl → verify sha256 → unpack into `/var/db/repos/gentoo`. Naming
  the sha as a build-arg *before* that layer is what finally gives the layer a cache buster, and
  is the direct fix for the never-invalidating tree layer described at the top.
- `scripts/stages/10-fetch.sh` does the same into the `-tree` volume, idempotently: if
  `metadata/timestamp.chk` already matches `SNAPSHOT_DATE` **and** a recorded sha marker matches,
  skip.

**Verify:** stage 30 asserts that the tree the depgraph is about to use matches the pin, before it
emerges anything. A stale `-tree` volume outliving a pin bump is the obvious silent failure this
design introduces, so it gets an assertion rather than a hope.

Once captured, the pin has no upstream dependency at all. Gentoo can rotate its snapshots on
whatever schedule it likes.

## Layer 2 — the version lock

Two files, each a sorted list of exact `=cat/pkg-ver` atoms, each directly usable as a Portage
set:

| File | Covers | Constrains | Verified at |
|---|---|---|---|
| `config/portage/lock/image.lock` | the pre-prune `--root=$TARGET` closure | stage 30's target emerge | end of stage 30 |
| `config/portage/lock/builder.lock` | the builder's own `/` closure | the Dockerfile's emerge | stage 20 |

**Constrain.** Stage 30's emerge takes the lock in place of the loose sets:

```
ROOT=$TARGET PORTAGE_CONFIGROOT=$CONFIG_ROOT \
  emerge --verbose --usepkg --with-bdeps=n --changed-use --quiet-build=y @locked-image
```

The lock is the **full closure**, not just the leaf atoms from `config/portage/sets/`. That is the
whole point — with every transitive dependency named at an exact version, the resolver has no
freedom left, and the lock is a constraint rather than a suggestion. Drift lives in transitive
dependencies, which is exactly what [03-package-set.md](03-package-set.md) declines to enumerate
by hand, and rightly so: this file is generated, never authored.

**Generate / relock.** A missing lock file, or an explicit `--relock`, emerges the loose `@base
@hardware @desktop` exactly as today, writes `out/reports/image.lock.generated` from the target
VDB, and `die`s telling the operator to review and commit it:

```
( cd "$TARGET/var/db/pkg" && printf '%s\n' */* | sed 's|^|=|' | sort )
```

This is deliberately the **same flow `expected-packages.txt` already uses** (`50-prune.sh:81-83`)
— build, review the generated file, commit it, re-run. It is the documented first-build experience
already; there is no reason to invent a second one.

**Verify.** Stage 30 diffs the resulting VDB against the lock and reports added and removed
*packages* separately from *version* changes, because those are different kinds of news and a
combined diff buries the first in the second.

**Do not add the lock files to `portage_config_hash()`.** `scripts/lib/common.sh:242-245` already
documents this trap for `expected-packages.txt` — "hashing it would make the guards below fire on
their own output" — and a lock that constrains the emerge is the same self-referential loop, one
step worse. Instead, record `portage_config_hash` *inside the lock header* and assert it one-way.
That catches "the config changed and the lock did not" without the cycle.

The coupling is worth stating plainly: flipping `INCLUDE_CJK_FONTS` or `INCLUDE_PRINTING` changes
the closure and therefore **requires a relock**. `filter_set_file` resolves those markers before
the set is ever emerged, so a lock generated with one setting is simply wrong for the other.

### expected-packages.txt keeps its job

The lock pins versions *upstream* of the prune; `config/portage/expected-packages.txt` gates the
set the prune *leaves behind*. Since the shipped set is a subset of the pre-prune closure, and the
closure is version-locked, a version-stripped gate is entirely sufficient downstream — every
version that can reach it has already been fixed by the lock.

So the audit gate described in [03-package-set.md](03-package-set.md) and
[06-pruning.md](06-pruning.md) stays exactly as it is. Two files, two distinct jobs, and no churn
through `plan/03`, `plan/06`, `plan/09`, `config/portage/package.mask/image` or
`config/portage/package.use/image`, all of which name it.

## Layer 3 — the builder toolchain

`builder/Dockerfile`'s fifteen explicit atoms pull roughly ninety-eight packages from the binhost,
none pinned. `builder.lock` constrains that emerge the same way `image.lock` constrains stage
30's.

**One implementation detail that is cheap to note now and irritating to discover later:**
`build.sh:112-113` builds with the context set to `$REPO_ROOT/builder`, so `COPY`ing
`config/portage/lock/builder.lock` into the image is impossible as things stand. The build context
has to move to `$REPO_ROOT`, with a `.dockerignore` to keep `out/` and `.claude/worktrees/` out of
it.

Degradation here is acceptable and self-healing. If the binhost no longer carries a locked
version, Portage compiles it from the pinned tree instead: slower, still correct, still
reproducible. That is the right trade — the binhost is a cache, and this makes the pipeline stop
treating it as a source of truth.

## Layer 4 — publish provenance

`scripts/stages/80-release.sh` gains `${DISTRO_ID}_<VERSION>.provenance.txt`, written into the
channel directory *before* `SHA256SUMS` is computed so it inherits the existing detached signature
for free.

**Does:** records `VERSION`, `SNAPSHOT_DATE`, `SNAPSHOT_SHA256`, `BUILDER_DIGEST`, `PROFILE`, the
Portage version, `portage_config_hash`, and the sha256 of each lock file.

**Verify:** the file appears in `SHA256SUMS`, and `gpgv` round-trips over it like every other
artifact.

This is what makes a shipped image auditable after the fact — given a release, you can reconstruct
the exact inputs that produced it without having the build host.

## Testing

A new `tests/test-pin-policy.sh` in the T0 tier of [07-testing.md](07-testing.md), modelled on the
existing `tests/test-binpkg-policy.sh` — offline, greps the sources, same shape:

- `BUILDER_DIGEST` and `SNAPSHOT_SHA256` are non-empty and well-formed.
- Lock files are sorted, unique, and every line matches `=cat/pkg-ver`.
- Stage 30 emerges the lock set when one is present.
- `builder/Dockerfile` pins the tree fetch and verifies its sha256.

Plus one determinism check that rides along with the existing T2 flow, which already runs two
builds sharing `/cache`: their `out/reports/packages-cpv.txt` must be byte-identical.
[07-testing.md](07-testing.md) has no package-level validation at all today, which is why version
drift could never have been caught by the test suite.

## Rejected alternatives

**Pin the tree by git SHA.** The rsync tree is published as git —
`anongit.gentoo.org/git/repo/sync/gentoo.git` and `github.com/gentoo-mirror/gentoo` are the same
repository — and it works: `git fetch --depth 1 origin <sha>` on a historical commit succeeds, the
tree carries `metadata/md5-cache` so no `egencache` pass is needed, and a depth-1 fetch is about
80 MB in seconds. Recorded here because it is the obvious thing to reach for and it is genuinely
viable. Rejected because it makes every future build depend on a third party keeping that history
reachable and not regenerating the mirror, and because it needs `dev-vcs/git` added to the
builder. The tarball we host ourselves has no such dependency once captured. Note also that
`metadata/timestamp.commit` in a synced tree names a commit in the *development* repo, whose SHAs
are not the sync repo's — a subtlety that would have to be handled correctly if this is ever
revisited.

**Per-atom pins in `package.accept_keywords` / `package.mask`,** scaling up the existing
`=kde-plasma/plasma-login-manager-6.6.6` approach. Rejected on the grounds
[03-package-set.md](03-package-set.md) already gives: "Listing them would only invite version pins
the set does not own." Hand-written pins also cover only what a human thought to list, and drift
lives in the transitive closure.

**Bit-identical builds.** Out of scope. `-T0` in [04-image-and-boot.md](04-image-and-boot.md) and
the roadmap bullet in [08-roadmap.md](08-roadmap.md) aim there; this document is the prerequisite,
not the delivery.

## Open questions

1. **Where do snapshots get hosted?** `SNAPSHOT_URL` assumes `immos.trinora.software/snapshots`
   next to the existing update channel. Roughly 47 MB per pin bump, retained indefinitely. If pins
   move monthly that is trivial; the question is only whether the same static host serves both.
2. **Should the tree tarball be signed by us too,** as the release artifacts are, or is the
   recorded sha256 in a committed `config/build.conf` sufficient? The sha is already covered by
   git history, which is arguably the stronger claim.
3. **Does `--relock` belong in `build.sh` as a flag, or as a separate script** like
   `capture-snapshot.sh`? It needs a full stage-30 run either way, so it is not cheap enough to
   feel like a flag.
4. **How stale can `builder.lock` get before the binhost fallback stops being a good trade?**
   Every locked version the binhost has dropped becomes a source build in the builder image, and
   the Dockerfile comment already notes that a full source build of that set costs about an hour.

## Sequencing

Layer 0 and the capture script are the prerequisites for everything else and are independently
useful — they make `SNAPSHOT_DATE` mean what it already claims to mean. The locks can follow once
the first Plasma build has produced a package set worth locking, which is the same build that has
to regenerate `expected-packages.txt` (see [09-kde-migration.md](09-kde-migration.md)). Doing both
from one build is the efficient order.

**Time-sensitive:** capture `gentoo-20260819.tar.xz` before the retention window closes, or the
current pin becomes unreproducible and the first locked build will be against a different tree
than 0.1.0 was.

---

*Not yet registered in the `## Document map` in [00-overview.md](00-overview.md) or the table in
`README.md`; both should gain a row when this is accepted.
[02-build-pipeline.md](02-build-pipeline.md)'s "Pinned inputs" bullet overstates the current state
and should point here, and [08-roadmap.md](08-roadmap.md) item 6 should distinguish
package-version reproducibility (this document) from identical-digest reproducibility (still
unstarted).*
