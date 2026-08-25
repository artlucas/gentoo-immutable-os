#!/usr/bin/env bash
# Stage 30 — the two-root emerge: build-time deps land in the builder, runtime deps
# land in $TARGET. The image is toolchain-free by construction (plan/02, plan/06).
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=30-target-rootfs
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/$STAGE_NAME.log") 2>&1

is_linux || die "stages run inside the builder container only"
[[ -d $CONFIG_ROOT/etc/portage ]] || die "config-root missing — run stage 20 first"

# ---- guards: two ways this stage silently built the wrong image ----------------------
#
# 1. STALE CONFIG ROOT. Only stage 20 copies config/portage/* into $CONFIG_ROOT, and
#    mirror_target_pkg_config reads from $CONFIG_ROOT — not from $REPO. So "build.sh --from 30"
#    after editing package.use/ resolves against the PREVIOUS run's flags and reports success:
#    the emerge output shows the old USE strings and nothing anywhere says why.
CUR_CFG_HASH="$(portage_config_hash)"
REC_CFG_HASH="$(cat "$CONFIG_ROOT/.inputs-hash" 2>/dev/null || echo none)"
[[ $CUR_CFG_HASH == "$REC_CFG_HASH" ]] || die "config/portage or build.conf changed since stage 20 last ran
  (config root fingerprint $REC_CFG_HASH != $CUR_CFG_HASH).
  \$CONFIG_ROOT is a copy, so this stage would resolve against the OLD flags.
  Re-run including stage 20:  scripts/build.sh --from 20"

# 2. STALE TARGET. This stage is resumable by design: it emerges into an existing $TARGET with
#    --changed-use, which REBUILDS packages whose flags changed but never REMOVES packages that
#    dropped out of the graph. A USE change that is meant to delete something (say
#    kwin[-lock], to drop kscreenlocker) therefore leaves the package installed and shipping,
#    while the emerge resolution — correctly — no longer lists it. Portage has no safe fix
#    here: the sets are not this root's @world, so --depclean would consider everything
#    orphaned. Refuse instead.
TARGET_HASH_FILE="$WORK/target-config-hash"
PREV_TGT_HASH="$(cat "$TARGET_HASH_FILE" 2>/dev/null || echo none)"
if [[ -d $TARGET/var/db/pkg && $PREV_TGT_HASH != none && $PREV_TGT_HASH != "$CUR_CFG_HASH" ]]; then
  die "config changed since $TARGET was populated, and --changed-use cannot remove packages
  from an existing root — anything a USE flag was meant to DELETE would still ship.
  Wipe the target and rebuild:  ${RUNTIME:-docker} volume rm -f ${DISTRO_ID}-work
  (the binpkg cache volume is separate and is kept, so the re-merge is mostly reinstalls)"
fi

# Same "/" mirror stage 20 sets up: build.sh runs every stage in its own --rm container, so
# stage 20's copy is already gone. Without this the depgraph resolves target packages against
# a stock "/" and dies on phantom slot conflicts (cairo:0) and REQUIRED_USE failures
# (media-libs/libcanberra's "udev? ( alsa )") for packages the image never asked for.
mirror_target_pkg_config

# Configure-time deps that only exist in RDEPEND upstream — see config/portage/sets/buildhost
# for the full explanation. Installed into the builder's "/", never into the image.
#
# --getbinpkg, unlike the target emerge below: builder-side packages come from the binhost,
# the same way builder/Dockerfile installs the rest of the builder's tools. "/" already has
# FEATURES=getbinpkg and the getuto trust store, so the flag only makes the intent explicit
# — but it is also why this is a SEPARATE emerge. --getbinpkg is per-invocation, not per-root
# (_emerge/actions.py derives it from the TARGET root's FEATURES and then populates every
# tree with it), so anything merged inside the target emerge below cannot use the binhost.
BUILDHOST_SET="$REPO/config/portage/sets/buildhost"
if [[ -s $BUILDHOST_SET ]]; then
  mapfile -t BUILDHOST_PKGS < <(sed -E 's/#.*//; /^[[:space:]]*$/d; s/[[:space:]]//g' "$BUILDHOST_SET")
  if (( ${#BUILDHOST_PKGS[@]} )); then
    log "builder-root configure deps: ${BUILDHOST_PKGS[*]}"
    emerge --oneshot --noreplace --usepkg --getbinpkg --quiet-build=y "${BUILDHOST_PKGS[@]}"
  fi
fi

SETS=(@base @hardware)
[[ ${CONSOLE_ONLY:-0} == 1 ]] || SETS+=(@desktop)
log "emerging into $TARGET: ${SETS[*]} (console-only=${CONSOLE_ONLY:-0})"

ensure_dir "$TARGET"
seed_merged_usr "$TARGET"
seed_target_dirs "$TARGET"

# The image is built from source, or from binpkgs this pipeline built earlier: the target's
# make.conf sets neither getbinpkg nor PORTAGE_BINHOST (config/portage/make.conf.in explains
# why), and --usepkg reads /cache/binpkgs only. Asserted here as well as in stage 20's verify
# block, because this is the config portage actually reads and because the failure is
# invisible in the emerge log — a remote binpkg merges exactly like a local one.
#
# This is also what used to force a getuto dance around the target root: with getbinpkg set,
# portage ran its trust helper against --root=$TARGET, which on a first build is an empty
# directory with no Gentoo release keys, so getuto exited 1 and took the whole emerge with it
# unless the keys were seeded in first. No remote bintree, no trust helper — populate() only
# reaches _run_trust_helper via _populate_remote (portage/dbapi/bintree.py).
tgt_features=" $(ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" portageq envvar FEATURES 2>/dev/null || true) "
[[ $tgt_features == *" getbinpkg "* ]] \
  && die "the target config enables FEATURES=getbinpkg, so this emerge would pull binaries
  built against the default profile's USE into the image. Image packages come from source or
  from /cache/binpkgs; the binhost belongs to the builder (config/portage/make.conf.in)"
tgt_binhost="$(ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" portageq envvar PORTAGE_BINHOST 2>/dev/null || true)"
[[ -n $tgt_binhost ]] \
  && die "the target config sets PORTAGE_BINHOST=$tgt_binhost (config/portage/make.conf.in)"

# BDEPEND → builder (/), RDEPEND → ROOT: portage's default ROOT semantics.
# --with-bdeps=n keeps build-only deps out of the target's depgraph.
# --usepkg without --getbinpkg: the only binaries this may reuse are the ones an earlier run
# of this pipeline built into /cache/binpkgs (FEATURES=buildpkg). Everything else compiles.
# --changed-use is not optional for a resumable pipeline: without it emerge leaves an
# already-installed package alone even when config/portage/package.use now says something
# different, so a build resumed with --from 30 silently keeps the old flags. That is how
# x11-misc/xdg-utils kept its perl deps after being switched to -perl, and it would let any
# later USE fix appear to apply while the image still carried the old build.
ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" \
  emerge --verbose --usepkg --with-bdeps=n --changed-use --quiet-build=y "${SETS[@]}"

# quick pre-prune report (full manifest + gate in stage 50)
ensure_dir "$REPORT_DIR"
# the target now matches this config; record it for the staleness guard above
printf '%s' "$CUR_CFG_HASH" > "$WORK/target-config-hash"

( cd "$TARGET/var/db/pkg" && printf '%s\n' */* | sort ) > "$REPORT_DIR/target-packages-cpv.txt"
log "target has $(wc -l < "$REPORT_DIR/target-packages-cpv.txt") packages"

# ---- verify -------------------------------------------------------------------
# NB: sys-devel/gcc IS expected here. It is in the profile's @system set, so portage installs
# it into any new ROOT, and it is the only provider of libstdc++.so.6 / libgcc_s.so.1. Stage 50
# splits it — compiler out, runtime libs in — and asserts the result. What must NOT appear is a
# second toolchain nothing in the image needs; those indicate a real --with-bdeps/USE mistake.
for leak in rustc clang ld as; do
  [[ -x $TARGET/usr/bin/$leak ]] \
    && die "verify: unexpected toolchain in target: $leak (check --with-bdeps / package list)"
done
[[ -d $TARGET/usr/lib/modules || -d $TARGET/lib/modules ]] \
  || die "verify: no kernel modules in target (gentoo-kernel-bin missing?)"
# check bin/ and sbin/ both: gdm's daemon installed to /usr/sbin, not /usr/bin, and an
# assertion that only looked in /usr/bin reported it missing from a target that had it. The
# same uncertainty applies to plasmalogin below — its path is inferred from the ebuild's other
# paths (/etc/plasmalogin.conf.d, /run/plasmalogin, the plasmalogin user and its three PAM
# stacks), not read off an installed file list — which is precisely why this check searches
# both and dies loudly. /usr/lib/systemd/system/distro-boot-ok.service.in names the same
# binary in a ConditionPathExists, and that one fails SILENTLY by skipping the unit.
have_exe() { local n=$1; [[ -x $TARGET/usr/bin/$n || -x $TARGET/usr/sbin/$n ]]; }
have_exe systemctl || die "verify: systemd missing from target"
have_exe flatpak   || die "verify: flatpak missing from target"
if [[ ${CONSOLE_ONLY:-0} != 1 ]]; then
  have_exe plasmalogin  || die "verify: plasmalogin missing from desktop target (kde-plasma/plasma-login-manager)"
  have_exe plasmashell  || die "verify: plasmashell missing from desktop target"
  # kwin is load-bearing twice over: it is the session compositor AND the compositor Plasma
  # Login Manager runs its greeter on. An image without it boots to a greeter and nothing else.
  have_exe kwin_wayland || die "verify: kwin_wayland missing from desktop target"
fi
log "target rootfs emerged OK"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" "$REPO"/config/portage/sets/* "$REPO"/config/portage/package.use/*)"
