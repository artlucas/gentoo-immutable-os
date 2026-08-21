#!/usr/bin/env bash
# Stage 20 — assemble the TARGET portage config-root at $WORK/config.
# emerge --config-root=$WORK/config controls everything merged into the image;
# the builder's own /etc/portage stays stock.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=20-builder-setup
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/$STAGE_NAME.log") 2>&1

is_linux || die "stages run inside the builder container only"

PC="$CONFIG_ROOT/etc/portage"
rm -rf -- "$CONFIG_ROOT"
ensure_dir "$PC"/{package.use,package.license,package.accept_keywords,package.mask,sets}

# profile symlink (profile tree lives in the builder's synced repo)
PROFILE_DIR="/var/db/repos/gentoo/profiles/$PROFILE"
[[ -d $PROFILE_DIR ]] || die "profile not found in repo: $PROFILE"
ln -sfn "$PROFILE_DIR" "$PC/make.profile"

# make.conf — rendered from repo template
JOBS="$(nproc)"
# L10N uses hyphens (pt-BR); LOCALES_KEEP uses underscores (pt_BR directory names)
L10N="$(printf '%s' "$LOCALES_KEEP" | tr '_' '-')"
export JOBS L10N BINHOST_URI
render_template "$REPO/config/portage/make.conf.in" "$PC/make.conf"

# straight copies
cp "$REPO"/config/portage/package.use/*             "$PC/package.use/"
cp "$REPO"/config/portage/package.license/*         "$PC/package.license/"
cp "$REPO"/config/portage/package.accept_keywords/* "$PC/package.accept_keywords/"
cp "$REPO"/config/portage/package.mask/*            "$PC/package.mask/"

# sets, with cjk/printing filtering per build.conf
for s in base hardware desktop; do
  filter_set_file "$REPO/config/portage/sets/$s" "$PC/sets/$s"
done

# repos.conf → builder's synced tree
ensure_dir "$PC/repos.conf"
cat > "$PC/repos.conf/gentoo.conf" <<'EOF'
[DEFAULT]
main-repo = gentoo
[gentoo]
location = /var/db/repos/gentoo
EOF

# Mirror the target's per-package config onto the builder's own "/" (see the function's
# comment in lib/common.sh for why the depgraph needs this). Stage 30 repeats the call —
# each stage is a separate container, so this does not persist.
mirror_target_pkg_config
log "mirrored target package.use/keywords/license onto builder /etc/portage"

ensure_dir /cache/binpkgs /cache/distfiles

# ---- verify ------------------------------------------------------------------
out="$(env ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" emerge --info 2>/dev/null | head -n1)"
log "emerge --info: $out"
grep -q 'x86-64' "$PC/make.conf" || die "verify: make.conf render failed"
[[ -e $PC/make.profile/eapi || -e $PC/make.profile/parent ]] || die "verify: bad profile symlink"
log "config-root assembled at $CONFIG_ROOT"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" "$REPO"/config/portage/make.conf.in "$REPO"/config/portage/sets/*)"
