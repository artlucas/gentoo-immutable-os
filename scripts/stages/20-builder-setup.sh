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
export JOBS L10N   # BINHOST_URI is the builder's own setting; the target has no binhost
render_template "$REPO/config/portage/make.conf.in" "$PC/make.conf"

# straight copies
cp "$REPO"/config/portage/package.use/*             "$PC/package.use/"
cp "$REPO"/config/portage/package.license/*         "$PC/package.license/"
cp "$REPO"/config/portage/package.accept_keywords/* "$PC/package.accept_keywords/"
cp "$REPO"/config/portage/package.mask/*            "$PC/package.mask/"

# Fingerprint of what was just copied. Stage 30 refuses to run against a config root that no
# longer matches the repo — see the guards there for the two ways that silently produced a
# wrong image before.
portage_config_hash > "$CONFIG_ROOT/.inputs-hash"

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

# /cache is a named volume and outlives any config change, so it can still hold binpkgs the
# official binhost served to an older build — back when the target's make.conf did set
# getbinpkg. Those are ordinary binpkgs to --usepkg, which has no idea where a package came
# from, so leaving them there would keep merging binhost binaries into images built by a
# config that no longer asks for any. Distfiles are untouched: source tarballs are exactly
# what building from source needs, and their Manifest checksums say what they are.
dropped="$(prune_binhost_binpkgs /cache/binpkgs)"
if (( dropped > 0 )); then
  log "dropped $dropped binhost-built binpkg(s) from /cache/binpkgs — they get rebuilt from source"
fi

# ---- verify ------------------------------------------------------------------
out="$(env ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" emerge --info 2>/dev/null | head -n1)"
log "emerge --info: $out"
grep -q 'x86-64' "$PC/make.conf" || die "verify: make.conf render failed"
# Image packages are built from source or from this pipeline's own binpkgs (plan/02). Both of
# these would silently reintroduce binhost binaries: FEATURES=getbinpkg on the target root is
# also what turns --getbinpkg on for the whole emerge invocation (_emerge/actions.py), and a
# PORTAGE_BINHOST with no getbinpkg is one --getbinpkg away from being live.
grep -qE '^[[:space:]]*FEATURES=.*getbinpkg' "$PC/make.conf" \
  && die "verify: target make.conf enables getbinpkg — the image is built from source
  (or from /cache/binpkgs); the binhost is the builder's, see config/portage/make.conf.in"
grep -qE '^[[:space:]]*PORTAGE_BINHOST=' "$PC/make.conf" \
  && die "verify: target make.conf sets PORTAGE_BINHOST — see config/portage/make.conf.in"
[[ -e $PC/make.profile/eapi || -e $PC/make.profile/parent ]] || die "verify: bad profile symlink"
log "config-root assembled at $CONFIG_ROOT"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" "$REPO"/config/portage/make.conf.in "$REPO"/config/portage/sets/*)"
