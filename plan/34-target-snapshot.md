# 34 — Snapshotting the target root for fast stage-30 re-runs

Stage 30 took 50 minutes and 13 seconds of the 2026-09-22 desktop build (19:30:36 → 20:20:49,
`out/logs`): 674 of 675 packages merged as binaries from `/cache/binpkgs`, three compiled from
source. Nothing compiled slowly and nothing downloaded — the time is the merges themselves, six
hundred and seventy-five of them in sequence, each writing a full file tree plus a VDB entry.

That cost is paid over and over, because stage 50 deletes the VDB at the end of every build
(`50-prune.sh` §2: `rm -rf -- "$T/var/db/pkg" …`). Portage's entire memory of what the target
already holds is that directory, so the next stage 30 to run — a relock, an added package, a GLSA
bump, any iteration that resumes from 30 after a finished build — finds what it can only treat as
an empty root and re-merges all 675 packages again. `relock.sh` says so out loud before you even
get there: *"stage 50 deletes the VDB at the end of a build, so a relock needs the target root
rebuilt first: `scripts/build.sh --only 20 && scripts/build.sh --only 30`"*.

The fix is the obvious one: keep a second copy of `$TARGET` exactly as stage 30 left it — VDB
intact, nothing configured, nothing pruned — and restore it at the top of the next stage 30. A
restore is minutes of local file copying; the emerge that follows sees a fully populated root and
merges only the delta. Everything the mechanism does is `rsync`, `rm` and one atomic `mv` inside
the existing `immos-work` volume, performed by the stage container that already exists: no
snapshot primitive is asked of the host, so it works identically under rootless Podman when the
pipeline is run self-hosted inside an Immos installation, where there is no btrfs, no LVM and no
root to ask (§6).

It also fixes a hazard class for free: today's endorsed post-build re-run merges into the tree
stage 50 already stripped — it converges only because everything re-merges — and `--from 40` on
that tree is the silently-unpatched-UKI ordering hazard `50-prune.sh` documents at its microcode
step. A restored target is byte-for-byte the pre-configure, pre-prune tree, so stages 40–60 re-run
against the state they were designed for.

## 1. What was decided before this was written

| Question | Answer |
|---|---|
| Restore even when config/lock changed since the snapshot? | **Yes — restore + reconcile.** Stage 30 gains an explicit removal step (§5) so "--changed-use cannot remove packages" stops being a reason to refuse. The relock flows — the headline payers of the 50 minutes — get the speedup |
| Where does the snapshot live? | An `rsync` directory beside the target in the work volume: `/work/target-snap<profile>`. One volume, one lifecycle — `--clean` and any `immos-work` wipe destroy target and snapshot together, so a snapshot can never outlive its lineage |
| Rootless constraint | Hard: no host-level snapshots (btrfs/LVM/ZFS), no loop devices, no reflink dependence, no new privileges. Plain file operations inside the mounted volume only (§6) |
| The escape hatch | `NO_TARGET_SNAPSHOT=1` disables both halves — write and restore — and the stage behaves exactly as before this document |

## 2. Why a re-run costs fifty minutes

Stage 30 is the two-root emerge ([plan/02](02-build-pipeline.md)): build-time deps into the
builder's `/`, the locked runtime closure into `$TARGET`. It is resumable *by design* — `emerge
--changed-use` into an existing root merges only what changed, which is why a mid-build failure
resumed with `--from 30` is cheap. Everything about the resume path assumes one thing: a VDB to
resume against.

Stage 50 removes it. Not as an accident — an image with no Portage has no use for a Portage
database ([plan/06](06-pruning.md)) — but the side effect is that after any completed build, the
target is no longer a merge base. The flows that then pay the full 50 minutes:

- **Relock, add a package, GLSA update** — the `docs/scenarios.md` headline flows, all of which
  route through "rebuild the target, then re-resolve". Each pays one full re-merge.
- **The stale-target guard firing** — `30-target-rootfs.sh` guard 2 dies with `docker volume rm -f
  immos-work`, and the recovery build re-merges everything (the binpkg cache makes it reinstalls,
  not compiles — 50 minutes of them).
- **Iteration on stages 40–70** — the [plan/32](32-installer-finish-and-lockup.md) /
  [plan/33](33-reinstall-keeping-files.md) working loop resumes `--from 30`, which today means
  merging into the pruned tree and reconstructing 675 packages onto it.

`docs/cache.md` is right that "a package present in `/cache/binpkgs` merges in seconds"; 675 of
them is the better part of an hour, and the tree being pre-pruned or pre-configured saves nothing
because an empty VDB re-merges regardless.

## 3. The snapshot — written at the end of stage 30

Only a target that passed everything is worth keeping, so the snapshot is written **after the
verify block and the lock verify, before `stamp_write`** — the last act of a successful stage 30.

The choreography, all inside `$WORK`:

1. `rsync -aHAX --numeric-ids --delete "$TARGET/" "$WORK/.target-snap<sfx>.tmp/"` — a full copy.
   `-X`/`-A` are not optional: stage 60 asserts file capabilities and ownership survive into the
   EROFS, so they must survive the snapshot too. `-H` keeps whatever hardlinks the tree has.
2. `rm -rf` the previous `/work/target-snap<sfx>`, then `mv` the tmp directory into place — `mv`
   within one volume is `rename(2)`, atomic and free. Between the `rm` and the `mv` there is a
   window with no snapshot; a crash there costs the next run the old full merge, nothing worse.
3. Write `/work/target-snap<sfx>.manifest` **last**, itself via tmp + `mv`. The manifest is the
   only thing that declares the snapshot valid, so an interrupted write can never restore half a
   tree — the manifest of the previous generation simply still names a directory that no longer
   exists, and validity checking treats that as absent (§4).

Manifest contents: the `target_closure_hash` and `portage_config_hash` the target was built
under, `BUILD_PROFILE`, `VERSION`, the tree pin (`SNAPSHOT_DATE`/`SNAPSHOT_SHA256`), the VDB atom
count, and the UTC timestamp. The hashes are not a restore precondition (§1 decided that); they
are what gets logged, what lands in `$TARGET_HASH_FILE` on restore, and what a human reads when
deciding whether to trust a snapshot.

One generation, rewritten in full on every successful stage 30. A no-op re-run therefore pays one
5 GiB copy to re-snapshot what it just restored — minutes, against the 50 it saved. Two
ping-pong generations would make updates incremental but double the disk cost for every profile;
rejected (§6).

| File | Change |
|---|---|
| `scripts/lib/common.sh` | `init_paths()` gains `TARGET_SNAP`, `TARGET_SNAP_TMP`, `TARGET_SNAP_MANIFEST`, suffixed beside `TARGET`/`TARGET_HASH_FILE` exactly as those are. New helpers beside the hash functions: `snapshot_write` (the choreography above), `snapshot_manifest_valid`, `snapshot_restore` (§4). No new tooling beyond the rsync the builder already carries |
| `scripts/stages/30-target-rootfs.sh` | The snapshot call, after the verify block, before `stamp_write`, skipped under `NO_TARGET_SNAPSHOT` |

## 4. The restore — at the top of stage 30

Restore happens when the live target **is not a valid merge base**, and only then. The condition
is evaluated after guard 1 (config-root freshness), which is unchanged and still comes first: a
restored tree does not excuse a stale `$CONFIG_ROOT`, and a config edit still forces `--from 20`.

| Live target | Snapshot | What stage 30 does |
|---|---|---|
| VDB present, hash file absent (first build) | — | Today's path: incremental emerge |
| VDB present, hash file matches current closure | — | Today's path: incremental emerge — no snapshot read, no cost |
| VDB present, hash mismatch (guard 2's case) | valid | **Restore**, then emerge + reconcile |
| VDB present, hash mismatch | none | Die, exactly today's message |
| Target absent, or VDB missing (post-50, post-wipe) | valid | **Restore**, then emerge + reconcile |
| Target absent, or VDB missing | none | Today's path: merge into whatever is there |

A snapshot is *valid* when its directory exists, its manifest parses, and the profile recorded in
it is the one being built — the per-profile suffix makes cross-profile restore a non-scenario,
and the manifest check makes a foreign or hand-mangled one refuse. An invalid snapshot logs one
warning naming the path and the escape (`delete it, or set NO_TARGET_SNAPSHOT=1`) and degrades to
the no-snapshot row above; it never dies, because a broken optional cache should not stop a build
that today would succeed without it.

The restore itself mirrors the write: `rsync -aHAX --numeric-ids` from the snapshot into
`$WORK/.target-restore<sfx>.tmp`, then an assertion — the restored VDB's atom count equals the
manifest's — then `rm -rf "$TARGET"` and the atomic `mv` into its place, then rewrite
`$TARGET_HASH_FILE` with the manifest's closure hash. An interrupted restore leaves only a tmp
directory, which the next run discards before starting; the live target is never the half-restored
one. The log says what happened and why, in one line each (§8).

Guard 2 changes shape around this. Its refusal exists because `--changed-use` never *removes*
packages that dropped out of the graph, so merging into a stale root ships things the config meant
to delete. A restored root is exactly such a root — which is why the restore path **skips the die
and owes a reconcile instead** (§5). The guard keeps its full strength on every row where no
restore happened: no snapshot, same refusal, same words.

## 5. The reconcile — what makes restore-plus-changed-config safe

After the emerge and before the lock verify, when `LOCKED == 1`:

1. Normalize the atoms of `$CONFIG_ROOT/etc/portage/sets/locked-image` — the intended closure,
   already exact `=cat/pkg-ver` pins.
2. `vdb_atoms "$TARGET"` minus that list — using the same normalization `lock_write` emits, so
   the two spellings cannot disagree — is the set of installed packages the current lock does not
   name.
3. Unmerge each, existence-guarded and logged per atom, `|| warn` on failure — the pattern stage
   50 §1 already uses for its build-only unmerges. Nothing is unmerged that anything kept still
   depends on, because the lock is the *full* closure: a package whose dependent survived would
   mean the dependent is in the lock, and then so is its dependency.
4. The existing bidirectional lock verify then runs, unchanged, and must come back clean — the
   reconcile did its job precisely when the diff that used to die with "wipe the target" is empty.

This split is the whole answer to guard 2's objection. "--changed-use cannot remove" is true in
two different cases, and they need two different mechanisms: a **package** dropping out of the
graph needs the unmerge above, and a **file** dropping out of a kept package (the `kwin[-lock]`
example in the guard's own comment) is a USE change, which `--changed-use` rebuilds. Together
they cover what the wholesale wipe used to be the only guarantee of — and the verify, the
expected-packages gate in stage 50, and every section-4 assertion still stand behind them.

Downgrades — a relock that pins an *older* version than the snapshot carries — are handled by the
same machinery: exact atoms are direct requirements, emerge installs them, the reconcile removes
nothing that is merely version-shifted, and the lock verify catches anything the resolver could
not do. When it does fire, the escape is the old one: `NO_TARGET_SNAPSHOT=1` and the volume wipe,
with the die text already saying so.

Unlocked builds (first build of a profile, no lock yet) never reconcile — there is no intended
closure to reconcile against — and never need to: an unlocked build has no snapshot either.

## 6. Rootless by construction

The constraint this design must not violate: the pipeline must also run **self-hosted, under
rootless Podman, inside an Immos installation** — the shipped OS's own podman
([plan/13](13-distrobox.md)), where there is no root, no btrfs, and no say over the host.

It holds, trivially and by construction, because the mechanism asks nothing of the host:

- A named volume under rootless Podman is a plain directory under the rootless storage root.
  Snapshot, tmp and target are three directories in one of them; `rsync`/`rm`/`mv` inside the
  stage container are unprivileged file operations on files that container already owns.
- Ownership never crosses a userns boundary. The snapshot is written, read back and replaced by
  the same container-user mapping that writes `$TARGET` itself — there is no `--user` dance of
  the kind `update-translations.sh` needs, because nothing is ever read back by the host account.
- The stage container's privileges are what stage 40's chroot already requires; stage 30 itself
  needs no new capability, device or mount for any of this.

The alternatives the constraint (or the cost) rejects:

| Alternative | Why not |
|---|---|
| btrfs subvolume snapshots / `btrfs send` | Requires the volume's filesystem to be btrfs. It is ext4 under Docker today and whatever `/var` is on the self-hosted install — never btrfs, and not changeable from inside the container |
| LVM / ZFS snapshots | Host block level, root to arrange; nonexistent in either target environment |
| `cp --reflink` | CoW filesystems only; everywhere else it silently becomes a full copy. As the *mechanism* that is a lie on ext4, and it buys nothing over rsync, which already gives the delete semantics and the file list. (Stage 40's existing `cp --reflink=auto` stays — opportunistic there, load-bearing never) |
| `tar` + `zstd` into `/cache` | Smaller on disk (~2 GiB), but slower to restore, and it puts build state in the volume whose contract is "kept across wipes" — a snapshot that outlives its work volume is a stale restore waiting to happen |
| A second named volume, cloned at the runtime level | The same rsync under a worse lifecycle: `build.sh` would own another volume, and `--clean`/`volume rm` would strand it |
| overlayfs whiteout reversal | Deletions read back as character devices; reversing them is not a restore mechanism, it is a research project |
| Two snapshot generations, updated incrementally | Halves the re-snapshot cost, doubles the disk for every profile, and buys minutes back on a path that is already minutes. Rejected for the same reason as the tarball: complexity priced above its savings |

## 7. Touchpoints

| File | Change |
|---|---|
| `scripts/lib/common.sh` | Path variables and the three helpers of §3–§4; `snapshot_restore` returns the reason the live target was not a base, for the log line |
| `scripts/stages/30-target-rootfs.sh` | The restore block between guard 1 and guard 2; guard 2's new arm (die only when no restore happened); the reconcile step between the emerge and the lock verify; the snapshot write before `stamp_write`; both halves behind `NO_TARGET_SNAPSHOT` |
| `scripts/relock.sh` | The VDB-missing die points at the short path: *"rebuild it from the snapshot — `scripts/build.sh --from 20` (stage 30 restores the target and merges the delta), then re-run this script"* — replacing `--only 20 && --only 30` |
| `scripts/build.sh` | `NO_TARGET_SNAPSHOT` joins the pass-through whitelist, beside `ALLOW_UNPINNED` and `RELOCK` |

`--clean` is deliberately untouched: it already removes the work volume wholesale, snapshot
included. Stage 50, `enter.sh` and `run-vm.sh` change nothing.

## 8. The words

Log lines and failures, English, one line each — the catalogue the tests pin:

| Where | Words |
|---|---|
| Snapshot written | `target snapshot written: /work/target-snap (675 packages, 5.4 GiB) — the next stage-30 re-run restores it instead of re-merging` |
| Restore, each reason | `live target is not a merge base (target absent / VDB missing / closure stale) — restoring the snapshot taken 2026-09-22 20:20 UTC (675 packages)` |
| Restore asserted | `restored target holds 675 packages; matches the manifest` |
| Reconcile, did something | `reconcile: unmerging 2 atoms the current lock does not name: sys-apps/foo-1.2 dev-libs/bar-2.3` |
| Reconcile, did nothing | `reconcile: nothing to remove` |
| Invalid snapshot | `warn: target snapshot manifest missing or unreadable — ignoring /work/target-snap (delete it, or set NO_TARGET_SNAPSHOT=1)` |
| Guard 2, no snapshot | Today's die, plus one clause: `…no valid snapshot for this profile exists, so there is nothing to restore` |

## 9. Tests

A new `tests/test-stage30-snapshot.sh`, offline, fixture trees — the suite's existing style —
plus extensions where this touches shared code:

| | |
|---|---|
| Manifest gating | A snapshot directory without a manifest, with a truncated manifest, and with a foreign profile in it: `snapshot_manifest_valid` is false for all three, and the restore decision table takes the no-snapshot row |
| Interrupted write | A tmp snapshot dir and stale manifest: validity check treats the pair as absent (the manifest names content the `rm -rf`/`mv` never finished replacing) |
| Interrupted restore | Junk in `$WORK/.target-restore<sfx>.tmp`: `snapshot_restore` discards it before copying, and the live target is untouched on failure |
| Post-restore assertion | Fixture snapshot whose VDB count disagrees with its manifest: restore fails loudly, target not replaced |
| The decision table | Fixture hash files and VDB presence driving all six rows of §4, including "guard 2 dies when no snapshot" and "guard 2's die is unreachable when a restore happened" |
| Reconcile | Fixture VDB of three atoms, lock naming two: the unmerge list is exactly the third; an empty difference logs nothing-to-remove; normalization agrees with `lock_write`'s spelling |
| Path plumbing | `init_paths` suffixes `TARGET_SNAP*` per profile exactly as it suffixes `TARGET`; desktop and installer snapshots cannot cross |
| Shared gates | Shellcheck over the new code; `test-pin-policy.sh` untouched and passing — the snapshot lives in `$WORK`, outside everything `portage_config_hash` reads |

## 10. Documentation (at implementation time)

Handbook rules as they stand: imperative tone, tables for matrices, no references to `plan/`,
paths as inline code.

| Page | Change |
|---|---|
| `docs/build.md` | Environment-variables matrix gains `NO_TARGET_SNAPSHOT=1` |
| `docs/cache.md` | "What is cached" gains the target snapshot; the invalidation matrix gains its row (invalidated by `--clean`, by a work-volume wipe, by profile); the stale-target recovery text stops assuming a re-merge |
| `docs/pipeline.md` | The stage-30 row and the staleness-guards paragraph: the restore, the reconcile, and the guard-2 arm that dies only without a snapshot |
| `docs/scenarios.md` | "Stale target guard fired" and the relock flows rewritten around the short path; timings re-worded after the first measured run |
| `README.md` | One sentence where the binpkg-cache paragraph promises fast rebuilds, so the promise matches the mechanism |

## 11. Known limits

- **Disk.** The work volume grows by one pre-configure target per profile — ≈5 GiB each, to be
  measured at execution: the whole pre-prune tree was 7,848 MiB on 2026-09-22, and 2,887 MiB of
  that is `/var`, largely the Flatpaks stage 40 installs *after* the snapshot point. Tight disks
  set `NO_TARGET_SNAPSHOT=1`.
- **Every successful stage 30 rewrites the snapshot in full.** One 5 GiB copy per successful run —
  minutes, deliberately not seconds (§3).
- **The snapshot is volume-local.** It is not the stage-90 vendor archive's business and cannot be
  carried between machines; `/cache/binpkgs` remains the portable cache, and offline builds are
  unchanged.
- **A first build has nothing to restore.** One 50-minute merge per profile lineage; the snapshot
  exists from the first successful stage 30 onward.
- **Downward relocks** (pins moved to older versions) ride exact atoms through the same emerge;
  anything the resolver will not do surfaces in the lock verify, whose escape remains
  `NO_TARGET_SNAPSHOT=1` plus the volume wipe — today's answer, unchanged.
- **Numbers are estimates until executed.** Restore and re-snapshot timings, and the true size of
  a post-30 tree, get their "measured on" lines from the first run of the implementation — the
  50m13s and the 7,848 MiB above are the only measured figures in this document.

## Changes to other documents

- **[plan/02](02-build-pipeline.md)** — Caching & rebuild speed: the snapshot paragraph, and the
  claim that a clean target rebuild is "minutes-fast" corrected to what 2026-09-22 measured —
  minutes per package, fifty for the set, now avoided rather than re-paid.
- **[plan/06](06-pruning.md)** — Where the VDB deletion is specified: a note that it costs every
  post-build stage-30 re-run a full re-merge, and that [plan/34](34-target-snapshot.md) is the
  recovery.
- **[plan/15](15-version-pinning.md)** — The relock recipe's rebuild step shortens to `--from 20`.
- **`docs/`** — as §10 lists, at implementation time.
