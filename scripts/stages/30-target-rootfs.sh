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

SETS=(@base @hardware)
[[ ${CONSOLE_ONLY:-0} == 1 ]] || SETS+=(@desktop)
log "emerging into $TARGET: ${SETS[*]} (console-only=${CONSOLE_ONLY:-0})"

ensure_dir "$TARGET"

# BDEPEND → builder (/), RDEPEND → ROOT: portage's default ROOT semantics.
# --with-bdeps=n keeps build-only deps out of the target's depgraph.
ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" \
  emerge --verbose --usepkg --with-bdeps=n --quiet-build=y "${SETS[@]}"

# quick pre-prune report (full manifest + gate in stage 50)
ensure_dir "$REPORT_DIR"
( cd "$TARGET/var/db/pkg" && printf '%s\n' */* | sort ) > "$REPORT_DIR/target-packages-cpv.txt"
log "target has $(wc -l < "$REPORT_DIR/target-packages-cpv.txt") packages"

# ---- verify -------------------------------------------------------------------
[[ -x $TARGET/usr/bin/gcc || -x $TARGET/usr/bin/cc ]] \
  && die "verify: compiler leaked into target — check --with-bdeps / package list"
[[ -d $TARGET/usr/lib/modules || -d $TARGET/lib/modules ]] \
  || die "verify: no kernel modules in target (gentoo-kernel-bin missing?)"
[[ -x $TARGET/usr/bin/systemctl ]] || die "verify: systemd missing from target"
[[ -x $TARGET/usr/bin/flatpak   ]] || die "verify: flatpak missing from target"
if [[ ${CONSOLE_ONLY:-0} != 1 ]]; then
  [[ -x $TARGET/usr/bin/sddm ]] || die "verify: sddm missing from desktop target"
fi
log "target rootfs emerged OK"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" "$REPO"/config/portage/sets/* "$REPO"/config/portage/package.use/*)"
