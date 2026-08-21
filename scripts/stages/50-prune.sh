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

# ---- 1b. portage tooling that leaked into the target ---------------------------------
# Nothing in the image RDEPENDs these: portage's own binhost machinery installs getuto (and
# with it sec-keys/openpgp-keys-gentoo-release -> app-portage/gemato -> the python requests
# stack) into whichever ROOT it is populating, and portage-utils arrives the same way. An
# image with no Portage has no use for Portage tooling (plan/06), so they are unmerged here —
# before the VDB is deleted below, while emerge can still do it cleanly.
for p in app-portage/gemato app-portage/getuto app-portage/portage-utils \
         sec-keys/openpgp-keys-gentoo-release; do
  [[ -d $T/var/db/pkg/${p%/*} ]] || continue
  compgen -G "$T/var/db/pkg/$p-*" >/dev/null || continue
  log "unmerging build-only package from image: $p"
  ROOT="$T" PORTAGE_CONFIGROOT="$CONFIG_ROOT" emerge --unmerge --quiet "$p" >/dev/null 2>&1 \
    || warn "could not unmerge $p"
done

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

# dev files: headers, pkg-config/cmake metadata, GIR XML, vala bindings. This used to be an
# INSTALL_MASK in the target make.conf, but that leaked onto the builder root and broke build
# deps there (see the note in config/portage/make.conf.in) — done here it touches only $TARGET.
# NB: /usr/lib64/girepository-1.0 (the binary typelibs) is deliberately NOT removed — gjs and
# gnome-shell load those at runtime. Only the build-time .gir XML and .vapi files go.
for d in usr/include usr/share/doc usr/share/info usr/share/man usr/share/gtk-doc \
         usr/share/devhelp usr/share/aclocal usr/lib64/pkgconfig usr/share/pkgconfig \
         usr/lib64/cmake usr/share/gir-1.0 usr/share/vala usr/share/zsh; do
  rm -rf -- "${T:?}/$d"
done

# ---- 3b. toolchain split: keep the gcc RUNTIME, delete the compiler ------------------
# sys-devel/gcc is in the profile's @system set (profiles/base/packages: *sys-devel/gcc), so
# portage installs it into any new ROOT — it is not something --with-bdeps=n can prevent, and
# it is also the only provider of libstdc++.so.6 / libgcc_s.so.1, which every C++ program in
# the image links against. plan/06's guarantee is about the SHIPPED IMAGE, so the split is:
# the ~270 MB of compiler (cc1/cc1plus/lto1 + drivers + headers + static libs) goes, the ~12 MB
# of runtime .so files stays, reachable through /etc/ld.so.conf.d/05gcc-*.conf.
GCC_LIBDIR="$(printf '%s\n' "$T"/usr/lib/gcc/*/* 2>/dev/null | head -n1)"
if [[ -n ${GCC_LIBDIR:-} && -d $GCC_LIBDIR ]]; then
  log "toolchain split: keeping $(basename -- "$(dirname -- "$GCC_LIBDIR")")/$(basename -- "$GCC_LIBDIR") runtime libs"
  rm -rf -- "$T/usr/libexec/gcc"                       # cc1, cc1plus, lto1, collect2
  rm -rf -- "$GCC_LIBDIR"/{include,include-fixed,plugin,install-tools}
  find "$GCC_LIBDIR" -maxdepth 1 \( -name '*.a' -o -name '*.o' \) -delete   # crt*.o, libgcc.a
  # compiler drivers and their toolchain helpers (the runtime .so files live elsewhere)
  local_bins=(gcc g++ cc c++ cpp gcov gcov-dump gcov-tool lto-dump gcc-ar gcc-nm gcc-ranlib gcc-config)
  for b in "${local_bins[@]}"; do
    rm -f -- "$T/usr/bin/$b" "$T/usr/bin/$b"-* "$T/usr/bin/${CHOST:-x86_64-pc-linux-gnu}-$b" \
             "$T/usr/bin/${CHOST:-x86_64-pc-linux-gnu}-$b"-*
  done
  rm -rf -- "$T/usr/share/gcc-data" "$T/usr/${CHOST:-x86_64-pc-linux-gnu}"
  # the loader must still find libstdc++/libgcc_s
  ls "$T"/etc/ld.so.conf.d/*gcc* >/dev/null 2>&1 \
    || warn "no gcc ld.so.conf.d entry — libstdc++ may be unfindable at runtime"
fi

# build-era files. target_mount() (lib/common.sh) seeds /etc/resolv.conf so the chroot can
# resolve during stages 30/40, and nothing removed it — so the *builder's* nameservers were
# shipping in the image's /etc lower dir. NetworkManager writes the real one on first boot;
# an absent file is the correct shipped state.
rm -f "$T/etc/resolv.conf.build" "$T/etc/resolv.conf"
rm -rf "$T/var/log"/* "$T/var/tmp"/* "$T/tmp"/*

# ---- 4. THE ASSERTIONS (build fails if any trips) ------------------------------------
fail=0
violation() { warn "PRUNE VIOLATION: $*"; fail=1; }

# NB: python/python3 are deliberately NOT in this list — see the interpreter note below.
for b in gcc g++ cc c++ cpp ld as ar make cmake ninja meson cargo rustc \
         emerge ebuild portageq pip; do
  hits="$(find "$T/usr/bin" "$T/usr/sbin" "$T/bin" "$T/sbin" \
            -maxdepth 1 \( -name "$b" -o -name "$b-*" \) 2>/dev/null || true)"
  [[ -n $hits ]] && violation "toolchain/interpreter binary present: $hits"
done

[[ -e $T/usr/include && -n $(ls -A "$T/usr/include" 2>/dev/null) ]] && violation "/usr/include not empty"
[[ -e $T/var/db/pkg    ]] && violation "VDB still present"
[[ -e $T/var/db/repos  ]] && violation "ebuild repo still present"
[[ -e $T/etc/portage   ]] && violation "/etc/portage still present"
# -L as well as -e: a resolv.conf symlink into /run is dangling at build time. If systemd-
# resolved is ever adopted, that symlink becomes the intended state and this line is what
# forces the change to be deliberate rather than silent.
[[ -e $T/etc/resolv.conf || -L $T/etc/resolv.conf ]] \
  && violation "builder /etc/resolv.conf shipped (see build-era cleanup above)"
find "$T" -xdev -name '*.la' 2>/dev/null | grep -q . && violation "*.la files remain"

# Interpreter policy (plan/06). The whitelist is no longer empty: dev-lang/python is a
# genuine RUNTIME dependency of gnome-base/gnome-shell on Gentoo — the ebuild folds
# DEPEND (which carries dev-python/docutils and dev-python/pygobject) into RDEPEND, so no
# amount of --with-bdeps=n keeps it out of a GNOME image. Admitted deliberately, per the
# rule this comment used to state: a human made the call, and it is recorded here, in
# plan/06 and in expected-packages.txt rather than tolerated silently.
#   allowed: dev-lang/python, dev-lang/python-exec, dev-python/{docutils,pygobject,pillow}
#            (+ app-admin/system-config-printer for the control-center printer panel)
#   allowed: dev-lang/perl + dev-perl/Parse-Yapp — net-fs/samba lists both in COMMON_DEPEND
#            unconditionally, and samba is a hard dep of gnome-control-center[cups] (the
#            printer panel). xdg-utils[-perl] keeps the other ~48 perl packages out.
#   still banned: pip and every compiler/build tool above.
# The toolchain-free guarantee itself is unchanged: no compiler, no Portage, no headers.

# the toolchain split must leave the runtime behind: a desktop with no libstdc++ boots to
# nothing, and that failure would otherwise only show up in QEMU (stage 70) or on hardware.
for lib in libstdc++.so.6 libgcc_s.so.1; do
  find "$T/usr/lib/gcc" -name "$lib" 2>/dev/null | grep -q . \
    || violation "gcc runtime library $lib missing after prune (toolchain split cut too deep)"
done

[[ $fail == 0 ]] || die "prune assertions failed — see PRUNE VIOLATION lines above"

du -xsm "$T" | tail -n1 | tee -a "$REPORT_DIR/size-report.txt"
log "prune complete, all assertions passed"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" "$REPO/config/prune-firmware.txt")"
