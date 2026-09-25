# Scenarios

Worked procedures for the common maintenance operations. Each assumes the machine has built the current release at least once, so the cache volumes and config root exist. `RELOCK=1` is required on any stage-20 or stage-30 preparation run that follows a config edit: stage 20's assertions (config hash, closure-shaping keys, stale atoms) all yield to it, and without it the relock recipe dies on its first stage.

## Security update: a GLSA affects a shipped package

A fixed version reaches the image only through the whole chain: a tree pin that carries the fix, a lock re-resolved against that tree, a version bump, and a rebuild. With the old pin nothing can move — stage 20 verifies every locked atom still exists in the pinned tree, and stage 30 emerges `@locked-image` only.

```sh
# 1. Move the tree pin in config/build.conf to a snapshot that carries the fix:
#      SNAPSHOT_DATE="20260904"
#      SNAPSHOT_SHA256="<sha256 of gentoo-20260904.tar.xz>"
#    Capture the pin while it is live: distfiles.gentoo.org keeps ~9 days of snapshots.
bash scripts/build.sh --only 10                # reconcile the tree volume with the new pin

# 2. Rebuild each profile's config root and target (stage 50 deleted the VDB after the last
#    completed build, so a re-resolve merges against the installed set — stage 30 restores the
#    target from its snapshot and merges only the delta, so this step is minutes, not a full
#    re-merge). RELOCK=1 because the pin edit moved the config hash and the committed locks
#    do not carry it yet.
for p in desktop console installer; do
  RELOCK=1 bash scripts/build.sh --profile $p --only 20
  RELOCK=1 bash scripts/build.sh --profile $p --only 30
done

# 3. Re-resolve each profile: move ONLY what has a security fix
scripts/relock.sh --security --profile desktop
scripts/relock.sh --security --profile console
scripts/relock.sh --security --profile installer

# 4. Review and apply, per profile (desktop shown; others under out/reports-<profile>/)
less out/reports/lock.diff
cp out/reports/desktop.lock.generated config/portage/lock/desktop.lock
cp out/reports-console/console.lock.generated config/portage/lock/console.lock
cp out/reports-installer/installer.lock.generated config/portage/lock/installer.lock

# 5. If the package is in the builder's closure (dracut, systemd/ukify, erofs-utils, qemu):
scripts/relock.sh --builder
cp out/reports/builder.lock.generated config/portage/lock/builder.lock

# 6. Bump VERSION in config/build.conf (strictly increasing), then build
$EDITOR config/build.conf
bash scripts/build.sh
```

Stage 20 in step 2 warns that locked atoms are gone from the new tree and continues — that is the relock doing its job; the re-resolve drops those atoms and re-adds their names unversioned.

Cache behavior on the final build: every atom the lock did not move merges from `/cache/binpkgs` in seconds; only the released packages (and anything their new versions force, such as an ABI change) compile. The builder image rebuilds only when `SNAPSHOT_DATE` or `builder.lock` moved — that is the expensive exception. Expect minutes to tens of minutes, not the first build's hours.

To audit whether any release has an open GLSA — with no rebuild and no target root — check out its commit and run step 3 alone: detection reads the committed lock, synthesizes the package database from it, and reports against the tree in the volume. `--security` needs no `RELOCK=1` stage runs when it finds nothing; the re-resolve emerge of step 2 is needed only when GLSAs were found and the target database is empty.

## Release one specific package

Move exactly the named atoms and nothing else:

```sh
scripts/relock.sh dev-libs/openssl --profile desktop
less out/reports/lock.diff
cp out/reports/desktop.lock.generated config/portage/lock/desktop.lock
```

Repeat per profile, bump `VERSION`, build. Everything not named stays at its locked version. The step-2 preparation from the scenario above applies whenever the target database is empty or the config hash moved.

## Add a package to the image

Add the atom to the appropriate set — `config/portage/sets/base`, `hardware`, `domain`, `desktop` or `installer` — then release it into the lock. A set entry alone never reaches the image: stage 30 emerges `@locked-image`, so an atom the lock does not name is never built.

```sh
$EDITOR config/portage/sets/desktop            # add the atom
RELOCK=1 bash scripts/build.sh --only 20       # the set edit moved the config hash
RELOCK=1 bash scripts/build.sh --only 30       # restore the target from its snapshot if the VDB is empty
scripts/relock.sh app-editors/helix --profile desktop
less out/reports/lock.diff                     # expect ADDED PACKAGES with the new closure
cp out/reports/desktop.lock.generated config/portage/lock/desktop.lock
bash scripts/build.sh                          # full run; stage 20 renders the new lock
```

For an ebuild added under `config/portage/overlay/`, name its `immos-<category>/<pkg>` atom the same way. Stage 50's audit gate fails the build if the image ships a package missing from `config/portage/expected-packages.<profile>.txt`; update that allowlist in the same commit.

## Config-only edit: relock nothing, restamp the hash

An edit under `config/portage` that no ebuild resolution can see — a comment, an overlay C++/QML/CMake source, a `build.conf` key no ebuild reads — still moves `PORTAGE_CONFIG_HASH` and stops every build in stage 20 until the lock headers carry the new value. A full re-resolve would move version pins as a side effect of a documentation-shaped edit; use the restamp instead:

```sh
$EDITOR config/portage/package.use/image       # the config-only edit
scripts/relock.sh --restamp
git diff config/portage/lock                   # one changed line per file, no atom moves
bash scripts/build.sh --from 20                # stage 20 rebuilds the config root with the new hash
```

`--restamp` refuses to run when a closure-shaping key (`SNAPSHOT_*`, `PROFILE`, `INCLUDE_*`, `PROFILE_ROLE`, `BUILD_PROFILE`, `PROFILE_SETS`) actually moved — that lock is genuinely stale and needs a re-resolve.

## Stale target guard fired: no snapshot to restore

Stage 30 refuses a stale target only when it has no valid snapshot to restore: an existing target root keeps every package the current config would drop, because `--changed-use` rebuilds but never removes (for example after a set entry was removed), and the restore-plus-reconcile path is what normally makes that safe. The guard firing at all therefore means the snapshot is absent (a first build), unreadable, or disabled with `NO_TARGET_SNAPSHOT=1`. The recovery keeps the binary cache:

```sh
docker volume rm -f immos-work
bash scripts/build.sh                          # stages 20-30 rebuild the target; merges come from /cache/binpkgs
```

Use `bash scripts/build.sh --clean` for the same effect plus stamp removal across profiles.

## Change the preinstalled Flatpaks

Two files govern the Flatpaks: `FLATPAK_PREINSTALL` in `config/build.conf` names the app IDs; `config/flatpak/apps.lock` pins every shipped ref — apps and runtimes — to an exact Flathub commit. Stage 40 installs the named apps, deploys every locked ref at its locked commit, removes every deployed ref the lock does not name, and readbacks the result against the lock.

`scripts/relock.sh --flatpak` records; it does not update. It reads the refs currently deployed in the target and writes them to `out/reports/apps.lock.generated`. Changing what ships therefore requires a target carrying the new state with the lock not pulling it back:

```sh
$EDITOR config/build.conf                      # FLATPAK_PREINSTALL: the app list
mv config/flatpak/apps.lock /tmp/apps.lock     # stage 40 then installs unpinned (it warns)
docker volume rm -f immos-work                 # a fresh target resolves installs against today's Flathub
bash scripts/build.sh --only 20                # stages 20-30 rebuild the target from the binpkg cache
bash scripts/build.sh --only 30
bash scripts/build.sh --only 40                # installs the app list at today's commits
mv /tmp/apps.lock config/flatpak/apps.lock     # the generator takes its header from the committed file
scripts/relock.sh --flatpak                    # records the deployed refs; exits non-zero by design
less out/reports/apps.lock.generated
cp out/reports/apps.lock.generated config/flatpak/apps.lock
bash scripts/build.sh                          # full build; stage 40 pins and readbacks every ref
```

The work-volume wipe is what lets existing refs move: `flatpak install` on an already-installed ref is a no-op, so on a fresh target alone do the installs resolve against Flathub's current state. The binpkg cache survives the wipe; stages 20–30 re-merge in minutes.

Failure mode: when a pinned commit has aged out of Flathub, stage 40's deploy fails and names the recovery — re-resolve the lock as above, or rebuild from the vendored archive (`--vendor-dir`), which still carries the objects. Vendor every release; Flathub's garbage collection makes `apps.lock` the least durable pin in the build.
