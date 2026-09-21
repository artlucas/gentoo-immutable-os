# Relock

Locks exist so a rebuild picks the same versions. `scripts/relock.sh` is the only sanctioned way a pin moves. It never commits anything: every mode writes a generated lock and a diff, then stops for review.

## When a re-resolve is necessary

| Change | Required action |
|---|---|
| `SNAPSHOT_DATE`/`SNAPSHOT_SHA256` moved to a newer tree | `scripts/relock.sh --security` (least change, the patch-release path) or `--all` (re-resolve everything — large diff) |
| Package added to a set in `config/portage/sets/`, or ebuild added under `config/portage/overlay/` | `scripts/relock.sh <atom>…` naming the new package(s) |
| One specific package must move (targeted release) | `scripts/relock.sh cat/pkg …` |
| Edit under `config/portage` that changes no resolution — comments, overlay C++/QML/CMake sources, keys no ebuild reads | `scripts/relock.sh --restamp` |
| Builder-closure package moved (dracut, systemd/ukify, erofs-utils, qemu — anything that builds the shipped initrd, UKI or rootfs) | `scripts/relock.sh --builder`, then rebuild the builder image |
| Flatpak app list (`FLATPAK_PREINSTALL`) or deployed versions changed | `scripts/relock.sh --flatpak` after an unpinned stage-40 run — see [Scenarios](scenarios.md#change-the-preinstalled-flatpaks) |

Anything that leaves `PORTAGE_CONFIG_HASH` stale stops the build in stage 20. A re-resolve (`--security`, `--all`, atoms) or a `--restamp` records the new hash; there is no third path.

## Modes

| Mode | What it moves | Profile-scoped | Requires |
|---|---|---|---|
| `--security` | Only packages with a GLSA against the committed lock | Yes (`--profile`, default `desktop`) | Populated tree volume, config root, populated target package database |
| `--all` | Every atom, re-resolved against the pinned tree | Yes | Same as `--security` |
| `<atom>…` | Only the named package names; everything else stays pinned | Yes | Same as `--security` |
| `--builder` | The builder's own closure | No | The built `immos-builder` image (its `@builder-request` set) |
| `--flatpak` | Nothing in portage; records the deployed Flatpak commits | No | A target with Flatpaks deployed (stage 40 has run) |
| `--restamp` | Nothing; rewrites the `PORTAGE_CONFIG_HASH` line in every image lock | All image locks at once | Nothing — runs host-side, no container, no tree, no network |

## Mechanism

Every re-resolve mode composes a temporary set by holding and releasing:

1. Take the committed lock.
2. Drop the atoms being released (named atoms, GLSA-affected names, or everything under `--all`), plus stale atoms the pinned tree no longer carries (recorded in `.lock-missing` by stage 20).
3. Add the released package names back unversioned.
4. Emerge that set into the target root and write the resulting installed closure as the generated lock.

Atoms still named at an exact version cannot move; released names float to the best version the pinned tree offers. That is the difference between a patch release and a wholesale upgrade, and the reason `--all` is a separate mode rather than the default.

The emerge clears the target's `world_sets` first: stage 30 records `@locked-image` there, and portage would otherwise enforce the old pins beside the relaxed set and skip every update without an error.

## Preconditions

The host half of `relock.sh` re-executes the same script inside the builder container with the same volumes `build.sh` uses. Before the container half can run, per profile being re-resolved:

```sh
bash scripts/build.sh --only 10                          # reconcile the tree volume after a snapshot-pin move
RELOCK=1 bash scripts/build.sh --profile <p> --only 20   # (re)build the config root and the locked-image set
RELOCK=1 bash scripts/build.sh --profile <p> --only 30   # populate the target's package database
```

`RELOCK=1` is required whenever the config hash moved since the locks were generated — always the case after a snapshot-pin move, which edits `config/build.conf`. Stage 20 then warns about atoms gone from the new tree and writes `.lock-missing` instead of dying; the re-resolve drops those atoms and re-adds their names unversioned. `relock.sh` sets `RELOCK=1` in its own container; a manual stage-20/30 preparation run through `build.sh` must export it.

The stage-30 step matters after any completed build: stage 50 deletes the target's `/var/db/pkg` at the end of every build, and a re-resolve merges against the installed set. `relock.sh` refuses an empty target database with the same instructions.

Detection under `--security` is the exception: it runs against a synthesized package database built from the committed lock, not against the target, so auditing whether a release has an open GLSA needs only the tree volume and the config root — no rebuild, and answerable for any past release by checking out its commit.

## Outputs and the apply flow

A profile re-resolve writes:

| File | Content |
|---|---|
| `out/reports[-<profile>]/<profile>.lock.generated` | The new lock, with a full provenance header |
| `out/reports[-<profile>]/lock.diff` | Three sections: `ADDED PACKAGES`, `REMOVED PACKAGES`, `VERSION CHANGES` |

Apply it:

```sh
less out/reports/lock.diff                                   # desktop; other profiles: out/reports-<profile>/
cp out/reports/desktop.lock.generated config/portage/lock/desktop.lock
```

Then bump `VERSION` in `config/build.conf` — it must strictly increase, and the `root_<VERSION>` GPT partlabel derives from it — and build. Commit the lock, the config change and the version bump together.

!!! note "Exit codes are part of the interface"
    The profile modes exit `0` whether or not the diff shows drift. `--builder` and `--flatpak` exit non-zero after writing their outputs, on purpose: nothing is applied without review, and the stop cannot be mistaken for success.

## Per-mode notes

### `--security`

GLSA detection builds a throwaway package database holding exactly the lock's atoms (SLOTs read from the pinned tree's `metadata/md5-cache`, because GLSA entries carry slot restrictions) and runs `glsa-check` against it. With no affected GLSA, the run reports nothing to relock and exits `0`. With affected GLSAs, the affected package names become the released atoms. `glsa-check` computes a least-change upgrade, which matches the patch-release question.

To audit a past release, check out its commit and run `scripts/relock.sh --security --profile <profile>`: the answer reads "no GLSA affects the locked package set" or the affected list, without building anything.

### `--builder`

Re-resolves the builder's own closure from the `@builder-request` set written by `builder/Dockerfile`, using binary packages from `BINHOST_URI`. Writes `out/reports/builder.lock.generated` and a diff. After copying it over `config/portage/lock/builder.lock`, the builder image must be rebuilt so its own root matches the lock it ships — the next `build.sh` run rebuilds it automatically because the copied file changed the Docker layer input.

### `--flatpak`

Reads the refs deployed in the target (`/work/target*/var/lib/flatpak/repo/refs/heads`), so stage 40 must have run for the current profile. Writes `out/reports/apps.lock.generated` and a diff against `config/flatpak/apps.lock`; copy it over the committed file when the change is intended. The mode records; it does not update — stage 40 pins every deployed ref back to its locked commit, so changing what ships requires a stage-40 run with the lock out of the way on a freshly built target. See [the worked procedure](scenarios.md#change-the-preinstalled-flatpaks). Stage 40's readback fails the build when a preinstalled app is missing from the lock or a pinned commit has aged out of Flathub.

### `--restamp`

Rewrites only the `PORTAGE_CONFIG_HASH` line in every image lock, in place, and changes no atom. Run it when `git diff config/` shows nothing but changes no ebuild resolution can see (comments, overlay sources, non-portage keys in `build.conf`). Verify the result:

```sh
git diff config/portage/lock    # one changed line per file, nothing else
```

Guards:

- Refuses when any closure-shaping key the lock records (`SNAPSHOT_DATE`, `SNAPSHOT_SHA256`, `PROFILE`, `INCLUDE_*`, `PROFILE_ROLE`, `BUILD_PROFILE`, `PROFILE_SETS`) now differs from the values in effect for that lock's profile. Those keys change which versions resolve; re-resolve with `--all --profile <name>` instead.
- Warns when the overlay gained a package that the profile's sets name but the lock does not carry: stage 30 emerges `@locked-image` only, so a restamp cannot make that package build. Release it properly with `scripts/relock.sh <atom> --profile <name>`.
- Skips `builder.lock`, which records no config hash by design.
