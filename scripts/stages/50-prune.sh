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

# ---- 3c. systemd-networkd: delete it, don't just disable it ---------------------------
# NetworkManager owns the network in this image (plan/03) and systemd-resolved owns DNS, so
# networkd has no job here. sys-apps/systemd has no USE flag that omits it — it is built
# unconditionally — so "not shipping it" has to happen with rm, here.
#
# Disabling was not enough on its own. The invariant "exactly one network manager" was held
# by preset lines plus stage 40's disable loop, which only warns on failure; a systemd bump
# that changes a vendor preset or adds a new unit re-enabling networkd would silently put the
# image back in the two-managers state that broke boot before (see 40-configure.sh and the
# preset file). A binary that isn't in the image cannot be re-enabled by anything.
#
# CAREFUL: /usr/lib/systemd/network holds BOTH networkd config and .link files. .link files
# are read by systemd-udevd, not networkd, and 99-default.link / 73-usb-net-by-mac.link drive
# interface naming and MAC policy — deleting them renames every NIC on the next boot. Only
# .network/.netdev (and their .example siblings) go.
log "removing systemd-networkd (NetworkManager owns the network)"
rm -f -- "$T/usr/lib/systemd/systemd-networkd" \
         "$T/usr/lib/systemd/systemd-networkd-wait-online" \
         "$T/usr/lib/systemd/systemd-network-generator" \
         "$T/usr/bin/networkctl" "$T/usr/sbin/networkctl"
rm -f -- "$T"/usr/lib/systemd/system/systemd-networkd*.service \
         "$T"/usr/lib/systemd/system/systemd-networkd*.socket \
         "$T"/usr/lib/systemd/system/systemd-network-generator.service
rm -f -- "$T"/usr/lib/systemd/network/*.network "$T"/usr/lib/systemd/network/*.netdev \
         "$T"/usr/lib/systemd/network/*.network.example "$T"/usr/lib/systemd/network/*.netdev.example
# D-Bus/polkit surface for org.freedesktop.network1, and the systemd-network user that only
# networkd ever ran as (its tmpfiles entries create /run/systemd/netif for that same user, so
# leaving them behind would make systemd-tmpfiles fail on an account nothing creates).
rm -f -- "$T/usr/share/dbus-1/system.d/org.freedesktop.network1.conf" \
         "$T/usr/share/dbus-1/system-services/org.freedesktop.network1.service" \
         "$T/usr/share/polkit-1/actions/org.freedesktop.network1.policy" \
         "$T/usr/lib/sysusers.d/systemd-network.conf" \
         "$T/usr/lib/tmpfiles.d/systemd-network.conf" \
         "$T/usr/share/bash-completion/completions/networkctl"
# Enablement symlinks. Stage 40 disables the units by preset, but preset-all also applies
# VENDOR presets, and a symlink left pointing at a unit file we just deleted makes systemd log
# "Unit ... not found" on every boot. Sweep the .wants/.requires dirs for danglers naming a
# networkd unit — in both /etc (what stage 40 wrote) and /usr (vendor-shipped).
while IFS= read -r link; do
  log "removing dangling networkd unit symlink: ${link#"$T"}"
  rm -f -- "$link"
done < <(find "$T/etc/systemd/system" "$T/usr/lib/systemd/system" -xdev -type l \
           \( -name 'systemd-networkd*' -o -name 'systemd-network-generator.service' \) 2>/dev/null)

# build-era files. target_mount() (lib/common.sh) seeds DNS for the chroot; since stage 40
# makes /etc/resolv.conf the symlink to systemd-resolved's stub, that seed lands in the tmpfs
# on /run and is already gone by now. Only the sidecar copy needs clearing here — resolv.conf
# itself is shipped state and is asserted below, not deleted.
rm -f "$T/etc/resolv.conf.build"
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
# /etc/resolv.conf must be the systemd-resolved stub symlink and nothing else. A regular file
# here means the builder's nameservers got baked into the image's /etc lower dir, which is
# exactly what happened before resolved was adopted. -L is tested first because the intended
# state — a symlink into /run — is dangling at build time and therefore invisible to -e.
if [[ -L $T/etc/resolv.conf ]]; then
  [[ "$(readlink "$T/etc/resolv.conf")" == ../run/systemd/resolve/stub-resolv.conf ]] \
    || violation "/etc/resolv.conf -> $(readlink "$T/etc/resolv.conf"), expected resolved's stub"
elif [[ -e $T/etc/resolv.conf ]]; then
  violation "builder /etc/resolv.conf shipped as a regular file (expected resolved's stub symlink)"
else
  violation "/etc/resolv.conf missing (stage 40 should have made it resolved's stub symlink)"
fi
# the resolver those point at, and the NSS module that reaches it, must survive the prune
[[ -x $T/usr/lib/systemd/systemd-resolved ]] || violation "systemd-resolved binary missing after prune"
compgen -G "$T/usr/lib64/libnss_resolve.so"* >/dev/null \
  || compgen -G "$T/usr/lib/libnss_resolve.so"* >/dev/null \
  || violation "libnss_resolve missing after prune (/etc/nsswitch.conf needs it)"
# ...and the resolver's counterpart must be gone: exactly one network manager, structurally.
for b in usr/lib/systemd/systemd-networkd usr/lib/systemd/systemd-networkd-wait-online \
         usr/lib/systemd/systemd-network-generator usr/bin/networkctl usr/sbin/networkctl; do
  [[ -e $T/$b ]] && violation "systemd-networkd residue present: /$b"
done
compgen -G "$T/usr/lib/systemd/system/systemd-networkd*" >/dev/null \
  && violation "systemd-networkd unit files still present"
# ...but the udev .link files must have survived: they are in networkd's directory and are not
# networkd's. Losing 99-default.link changes interface naming, which would only show up as a
# machine that boots with no network.
[[ -f $T/usr/lib/systemd/network/99-default.link ]] \
  || violation "/usr/lib/systemd/network/99-default.link removed — udev link policy is not networkd's, the prune cut too deep"
# NetworkManager itself is the whole point of removing networkd; assert it outlived it.
compgen -G "$T/usr/sbin/NetworkManager" >/dev/null \
  || compgen -G "$T/usr/bin/NetworkManager" >/dev/null \
  || compgen -G "$T/usr/libexec/NetworkManager" >/dev/null \
  || violation "NetworkManager binary missing after prune — the image has no network manager at all"
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
