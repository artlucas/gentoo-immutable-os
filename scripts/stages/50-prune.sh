#!/usr/bin/env bash
# Stage 50 — prune Portage/toolchain residue and ASSERT the toolchain-free guarantee
# (plan/06). Audit artifacts are saved before anything is deleted.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=50-prune
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/$STAGE_NAME.log") 2>&1

is_linux || die "stages run inside the builder container only"
T="$TARGET"
[[ -d $T/var/db/pkg ]] || die "target VDB missing — run stages 30/40 first (or already pruned: use build.sh --from 30 to rebuild)"

# ---- 1. audit artifacts (BEFORE deletion) -------------------------------------
ensure_dir "$REPORT_DIR"
( cd "$T/var/db/pkg" && printf '%s\n' */* | sort ) > "$REPORT_DIR/packages-cpv.txt"
# strip versions: category/name-1.2.3[-r4] → category/name
sed -E 's/-[0-9][^/]*$//' "$REPORT_DIR/packages-cpv.txt" | sort -u > "$REPORT_DIR/packages.txt"

ensure_dir "$T/usr/share/$DISTRO_ID"
cp "$REPORT_DIR/packages-cpv.txt" "$T/usr/share/$DISTRO_ID/manifest.txt"

# dependency-audit gate: unexplained new runtime deps fail the build (plan/03)
EXPECTED="$REPO/config/portage/expected-packages.txt"
if [[ -f $EXPECTED ]]; then
  if ! diff -u <(grep -v '^#' "$EXPECTED" | sed '/^$/d' | sort -u) "$REPORT_DIR/packages.txt" > "$REPORT_DIR/packages.diff"; then
    cat "$REPORT_DIR/packages.diff"
    die "package set drifted from config/portage/expected-packages.txt — review the diff; update the file deliberately if the change is intended"
  fi
  log "package set matches expected-packages.txt"
else
  cp "$REPORT_DIR/packages.txt" "$REPORT_DIR/expected-packages.txt.generated"
  die "no expected-packages.txt yet (first build): review $REPORT_DIR/expected-packages.txt.generated, commit it as config/portage/expected-packages.txt, then re-run --from 50"
fi

du -xsm "$T"/usr "$T"/usr/lib/firmware "$T"/usr/lib/modules "$T"/var 2>/dev/null \
  > "$REPORT_DIR/size-report.txt" || true

# ---- 2. delete Portage artifacts ------------------------------------------------
rm -rf -- "$T/var/db/pkg" "$T/var/db/repos" "$T/var/cache"/* \
          "$T/etc/portage" "$T/usr/share/portage"

# ---- 3. runtime-useless residue ---------------------------------------------------
find "$T" -xdev -name '*.la' -delete
find "$T/usr/lib64" -maxdepth 1 -name '*.a' -delete 2>/dev/null || true
find "$T/usr/lib/modules" -maxdepth 2 \( -name build -o -name source \) -exec rm -rf {} + 2>/dev/null || true
rm -rf -- "${T:?}/boot"/* 2>/dev/null || true  # UKI lives on the ESP; image /boot stays empty
find "$T" -xdev -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

# locale trim: keep LOCALES_KEEP prefixes (en also keeps en_GB etc.)
if [[ -d $T/usr/share/locale ]]; then
  for d in "$T/usr/share/locale"/*/; do
    base="$(basename -- "$d")"
    keep=0
    for l in $LOCALES_KEEP; do
      [[ $base == "$l" || $base == "${l%%_*}" || $base == "${l}"* || $base == "${l%%_*}_"* ]] && { keep=1; break; }
    done
    [[ $keep == 1 ]] || rm -rf -- "$d"
  done
fi

# firmware classes outside the desktop/laptop scope
if [[ -f $REPO/config/prune-firmware.txt && -d $T/usr/lib/firmware ]]; then
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    rm -rf -- "$T/usr/lib/firmware/$line"
  done < "$REPO/config/prune-firmware.txt"
fi

# build-era files
rm -f "$T/etc/resolv.conf.build"
rm -rf "$T/var/log"/* "$T/var/tmp"/* "$T/tmp"/*

# ---- 4. THE ASSERTIONS (build fails if any trips) ------------------------------------
fail=0
violation() { warn "PRUNE VIOLATION: $*"; fail=1; }

for b in gcc g++ cc c++ cpp ld as ar make cmake ninja meson cargo rustc \
         emerge ebuild portageq python python3 perl pip; do
  hits="$(find "$T/usr/bin" "$T/usr/sbin" "$T/bin" "$T/sbin" \
            -maxdepth 1 \( -name "$b" -o -name "$b-*" \) 2>/dev/null || true)"
  [[ -n $hits ]] && violation "toolchain/interpreter binary present: $hits"
done

[[ -e $T/usr/include && -n $(ls -A "$T/usr/include" 2>/dev/null) ]] && violation "/usr/include not empty"
[[ -e $T/var/db/pkg    ]] && violation "VDB still present"
[[ -e $T/var/db/repos  ]] && violation "ebuild repo still present"
[[ -e $T/etc/portage   ]] && violation "/etc/portage still present"
find "$T" -xdev -name '*.la' 2>/dev/null | grep -q . && violation "*.la files remain"

# interpreter whitelist is EMPTY by design (plan/06): python/perl arriving is a
# decision a human makes by editing config/portage/expected-packages.txt AND the
# assertion list above — not something the build tolerates silently.

[[ $fail == 0 ]] || die "prune assertions failed — see PRUNE VIOLATION lines above"

du -xsm "$T" | tail -n1 | tee -a "$REPORT_DIR/size-report.txt"
log "prune complete, all assertions passed"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" "$REPO/config/prune-firmware.txt")"
