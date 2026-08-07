#!/usr/bin/env bash
# Stage 80 — assemble the static-server release layout (plan/05):
#   release/<channel>/{SHA256SUMS[.gpg], <id>_<ver>.root.erofs.zst, <id>_<ver>.efi, img/}
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=80-release
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/$STAGE_NAME.log") 2>&1

ROOT_EROFS="$OUT/$ROOT_IMG_NAME"
[[ -f $ROOT_EROFS ]] || die "root image missing — run stage 60"
[[ -s $UKI_DIR/$UKI_NAME ]] || die "UKI missing — run stage 40"

ensure_dir "$RELEASE_DIR/img"

zstd -T0 -f -q "$ROOT_EROFS" -o "$RELEASE_DIR/${ROOT_IMG_NAME}.zst"
cp -f "$UKI_DIR/$UKI_NAME" "$RELEASE_DIR/$UKI_NAME"
[[ -f $OUT/$IMG_NAME.zst ]] && cp -f "$OUT/$IMG_NAME.zst" "$RELEASE_DIR/img/"

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
log "release assembled: $RELEASE_DIR"
ls -la "$RELEASE_DIR"
stamp_write "$STAGE_NAME" "$(inputs_hash "$RELEASE_DIR/SHA256SUMS")"
