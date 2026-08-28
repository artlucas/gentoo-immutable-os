#!/usr/bin/env bash
# Stage 80 — assemble the static-server release layout (plan/05):
#   release/<channel>/{SHA256SUMS[.gpg], <id>_<ver>.root.erofs.zst, <id>_<ver>.efi, img/}
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=80-release
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$LOG_DIR"; exec > >(tee -a "$LOG_DIR/$STAGE_NAME.log") 2>&1

ROOT_EROFS="$OUT/$ROOT_IMG_NAME"
[[ -f $ROOT_EROFS ]] || die "root image missing — run stage 60"
[[ -s $UKI_DIR/$UKI_NAME ]] || die "UKI missing — run stage 40"

# A release must never come from a build whose stage3 base was the floating tag. build.sh
# drops this marker when ALLOW_UNPINNED=1 was used, and removes it on any pinned build, so
# this cannot go stale in the direction that matters.
[[ -f $STATE_DIR/unpinned-build ]] && die "this build ran with ALLOW_UNPINNED=1, so its stage3
  base was the floating $BUILDER_IMAGE tag and its inputs are not recorded by anything.
  That is fine for a throwaway dev image and not fine for a release. Set BUILDER_DIGEST in
  config/build.conf and rebuild."

ensure_dir "$RELEASE_DIR/img"

zstd -T0 -f -q "$ROOT_EROFS" -o "$RELEASE_DIR/${ROOT_IMG_NAME}.zst"
cp -f "$UKI_DIR/$UKI_NAME" "$RELEASE_DIR/$UKI_NAME"
[[ -f $OUT/$IMG_NAME.zst ]] && cp -f "$OUT/$IMG_NAME.zst" "$RELEASE_DIR/img/"

# ---- provenance (plan/15 layer 6) ----------------------------------------------------
# Written BEFORE SHA256SUMS so it is covered by the existing detached signature for free.
# This is what makes a shipped image auditable without the build host: given a release, you can
# reconstruct exactly which tree, base image, profile and package versions produced it.
PROV="$RELEASE_DIR/${DISTRO_ID}_${VERSION}.provenance.txt"
{
  printf '# %s %s — build provenance\n' "$DISTRO_NAME" "$VERSION"
  printf '# Covered by SHA256SUMS(.gpg) in this directory.\n#\n'
  printf 'version: %s\n'            "$VERSION"
  printf 'channel: %s\n'            "$UPDATE_CHANNEL"
  printf 'snapshot_date: %s\n'      "$SNAPSHOT_DATE"
  printf 'snapshot_sha256: %s\n'    "$SNAPSHOT_SHA256"
  printf 'builder_image: %s\n'      "$BUILDER_IMAGE"
  printf 'builder_digest: %s\n'     "$BUILDER_DIGEST"
  printf 'profile: %s\n'            "$PROFILE"
  printf 'portage_version: %s\n'    "$(emerge --version 2>/dev/null | head -n1)"
  printf 'portage_config_hash: %s\n' "$(portage_config_hash)"
  printf 'build_profile: %s\n'      "$BUILD_PROFILE"
  printf 'profile_sets: %s\n'       "$PROFILE_SETS"
  printf 'include_cjk_fonts: %s\n'  "${INCLUDE_CJK_FONTS:-1}"
  printf 'include_printing: %s\n'   "${INCLUDE_PRINTING:-1}"
  printf 'include_distrobox: %s\n'  "${INCLUDE_DISTROBOX:-1}"
  # The locks by hash rather than by content: the files are thousands of lines, and the hash is
  # what lets you prove a checkout matches the release.
  for l in "$LOCK_DIR"/image.lock "$LOCK_DIR"/builder.lock "$REPO/config/flatpak/apps.lock"; do
    [[ -f $l ]] && printf 'lock_sha256: %s  %s\n' "$(sha256_file "$l")" "${l#"$REPO"/}"
  done
  # USE flags are deliberately not locked (plan/15) — portage_config_hash above is what pins
  # them, and this line is the pointer for anyone reading provenance and wondering.
  printf '# USE flags are pinned by portage_config_hash, not per-package; see plan/15.\n'
} > "$PROV"
log "provenance written: ${PROV#"$OUT"/}"

# SHA256SUMS covers every artifact in the channel dir (all retained versions),
# so one manifest always describes the whole channel.
( cd "$RELEASE_DIR" && find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -printf '%f\n' \
    | sort | xargs sha256sum > SHA256SUMS )

if [[ -n ${RELEASE_GPG_KEY:-} ]]; then
  gpg --batch --yes --local-user "$RELEASE_GPG_KEY" \
      --detach-sign --output "$RELEASE_DIR/SHA256SUMS.gpg" "$RELEASE_DIR/SHA256SUMS"
  # round-trip against the pubring shipped in images
  if [[ -f $REPO/config/keys/import-pubring.gpg ]]; then
    gpgv --keyring "$REPO/config/keys/import-pubring.gpg" \
         "$RELEASE_DIR/SHA256SUMS.gpg" "$RELEASE_DIR/SHA256SUMS" \
      || die "verify: signature does not validate against config/keys/import-pubring.gpg (images will refuse this update!)"
  else
    warn "no config/keys/import-pubring.gpg to round-trip the signature against"
  fi
elif [[ $UPDATE_VERIFY == 1 ]]; then
  die "UPDATE_VERIFY=1 but RELEASE_GPG_KEY is not set — images require signed updates"
else
  warn "unsigned release (UPDATE_VERIFY=0 dev mode)"
fi

# ---- verify -------------------------------------------------------------------
grep -q "$UKI_NAME" "$RELEASE_DIR/SHA256SUMS" || die "verify: UKI not in SHA256SUMS"
grep -q "${ROOT_IMG_NAME}.zst" "$RELEASE_DIR/SHA256SUMS" || die "verify: root image not in SHA256SUMS"
grep -q "${DISTRO_ID}_${VERSION}.provenance.txt" "$RELEASE_DIR/SHA256SUMS" \
  || die "verify: provenance not in SHA256SUMS — it must be written before the manifest"
log "release assembled: $RELEASE_DIR"
ls -la "$RELEASE_DIR"
stamp_write "$STAGE_NAME" "$(inputs_hash "$RELEASE_DIR/SHA256SUMS")"
