#!/usr/bin/env bash
# Stage 50 — prune Portage/toolchain residue and ASSERT the toolchain-free guarantee
# (plan/06). Audit artifacts are saved before anything is deleted.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=50-prune
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$LOG_DIR"; exec > >(tee -a "$LOG_DIR/$STAGE_NAME.log") 2>&1

is_linux || die "stages run inside the builder container only"
T="$TARGET"
[[ -d $T/var/db/pkg ]] || die "target VDB missing — run stages 30/40 first (or already pruned: use build.sh --from 30 to rebuild)"

# ---- 1. build-only packages that leaked into the target -----------------------------
#
# ORDER: this runs BEFORE the audit below, and that ordering is load-bearing. packages.txt is
# the file the dependency-audit gate compares against config/portage/expected-packages.txt,
# and it is built by listing the VDB. Generated before this unmerge, it listed ~8 packages
# that the very next step deleted — so the committed allowlist had to contain phantom entries
# for the gate to pass, and the same build produced a different packages.txt depending on
# whether stage 50 had run once or twice (a resumed --from 50 sees an already-unmerged VDB).
# Unmerging first makes packages.txt mean "what ships", which is what the gate is for.
# Nothing in the image needs these at runtime: sys-apps/portage is in the profile's @system
# set, so it lands in any ROOT portage populates, and its RDEPEND (USE=-build) drags
# app-portage/getuto -> sec-keys/openpgp-keys-gentoo-release, plus app-portage/gemato and the
# python requests stack behind USE=rsync-verify; app-portage/portage-utils rides in with the
# same Portage tooling. This has nothing to do with binhosts — the target uses none
# (config/portage/make.conf.in) and they still arrive. An image with no Portage has no use for
# Portage tooling (plan/06), so they are unmerged here — before the VDB is deleted below,
# while emerge can still do it cleanly.
#
# The llvm-core and dev-python entries below are the same story from different directions.
# llvm-core/llvmgold is an LTO plugin for a linker this image does not have, and
# llvm-core/llvm-toolchain-symlinks is nothing but symlinks into the /usr/lib/llvm/*/bin tree
# deleted in section 3 — both would be pure danglers. The dev-python packaging stack
# (setuptools/wheel/ensurepip-pip and their metadata deps) is build machinery that rides in on
# dev-lang/python; ensurepip-pip in particular ships a bundled pip wheel in an image whose
# section-4 assertions ban the pip binary outright. These entries are all guarded by existence
# checks, so they are harmless if the package never arrives.
#
# NB: the chain that forced python in is GONE. gnome-base/gnome-shell's ebuild folded DEPEND
# (dev-python/{docutils,pygobject}) into RDEPEND, which no --with-bdeps=n could undo; that
# package is not in this image any more. Whether python survives at all under Plasma is a
# question for the first build's expected-packages.txt, NOT something to pre-empt here — see
# the interpreter policy note in section 4.
#
# app-admin/perl-cleaner and sys-apps/portage are the tail of a third chain, and the one that
# actually tripped the section-4 assertions: dev-lang/perl (kept deliberately for samba, see
# plan/06) pulls perl-cleaner, whose whole job is rebuilding perl modules after a perl upgrade
# — meaningless on a read-only image with no compiler — and perl-cleaner RDEPENDs sys-apps/
# portage, which put /usr/bin/{ebuild,portageq,emerge-webrsync} in an image whose entire premise
# is "no Portage at runtime". Order matters: perl-cleaner is unmerged before portage, since it
# depends on it. This never showed up before because it takes a from-scratch target to resolve
# perl's full RDEPEND; an incrementally-built root had already settled without it.
# The perl chain SURVIVES the desktop swap intact — only its holder changed, from
# gnome-control-center[cups] -> system-config-printer -> samba to kde-apps/kio-extras[samba]
# directly (package.use/image, plan/06).
for p in app-portage/gemato app-portage/getuto app-portage/portage-utils \
         sec-keys/openpgp-keys-gentoo-release \
         llvm-core/llvmgold llvm-core/llvm-toolchain-symlinks \
         dev-python/ensurepip-pip dev-python/wheel dev-python/setuptools-scm \
         dev-python/trove-classifiers dev-python/vcs-versioning \
         app-admin/perl-cleaner sys-apps/portage; do
  [[ -d $T/var/db/pkg/${p%/*} ]] || continue
  compgen -G "$T/var/db/pkg/$p-*" >/dev/null || continue
  log "unmerging build-only package from image: $p"
  ROOT="$T" PORTAGE_CONFIGROOT="$CONFIG_ROOT" emerge --unmerge --quiet "$p" >/dev/null 2>&1 \
    || warn "could not unmerge $p"
done

# ---- 1b. audit artifacts (AFTER the unmerge above, BEFORE any deletion) --------------
ensure_dir "$REPORT_DIR"
( cd "$T/var/db/pkg" && printf '%s\n' */* | sort ) > "$REPORT_DIR/packages-cpv.txt"
# strip versions: category/name-1.2.3[-r4] → category/name
sed -E 's/-[0-9][^/]*$//' "$REPORT_DIR/packages-cpv.txt" | sort -u > "$REPORT_DIR/packages.txt"

ensure_dir "$T/usr/share/$DISTRO_ID"
cp "$REPORT_DIR/packages-cpv.txt" "$T/usr/share/$DISTRO_ID/manifest.txt"

# dependency-audit gate: unexplained new runtime deps fail the build (plan/03)
# Per-profile (plan/16 §3.3). This file is the hard guarantee that one profile's packages
# cannot appear in another's image: stage 50 fails the build on any unexplained addition, so
# "the installer never reaches an installed system" is an assertion, not a convention.
EXPECTED="${EXPECTED_PACKAGES:?init_paths did not set EXPECTED_PACKAGES}"
if [[ -f $EXPECTED ]]; then
  if ! diff -u <(grep -v '^#' "$EXPECTED" | sed '/^$/d' | sort -u) "$REPORT_DIR/packages.txt" > "$REPORT_DIR/packages.diff"; then
    cat "$REPORT_DIR/packages.diff"
    die "package set drifted from config/portage/expected-packages.${BUILD_PROFILE}.txt — review the diff; update the file deliberately if the change is intended"
  fi
  log "package set matches expected-packages.${BUILD_PROFILE}.txt"
else
  cp "$REPORT_DIR/packages.txt" "$REPORT_DIR/expected-packages.txt.generated"
  die "no expected-packages.${BUILD_PROFILE}.txt yet (first build of this profile): review
  $REPORT_DIR/expected-packages.txt.generated, commit it as
  config/portage/expected-packages.${BUILD_PROFILE}.txt, then re-run --from 50"
fi

# NB: no -x here. /var is a separate mount inside the builder, so "du -x" silently skipped it
# along with any other row on a different filesystem, and "2>/dev/null || true" hid the reason —
# which meant the firmware/modules rows plan/06 says to check against the budget table never
# appeared at all. The rows below are the ones that budget actually itemises.
du -sm "$T"/usr/src "$T"/usr/lib/firmware "$T"/usr/lib/modules "$T"/usr/lib/llvm \
       "$T"/usr/share/fonts "$T"/usr/share/locale "$T"/usr/share/icons "$T"/usr/lib64 \
       "$T"/usr "$T"/var > "$REPORT_DIR/size-report.txt"

# ---- 2. delete Portage artifacts ------------------------------------------------
rm -rf -- "$T/var/db/pkg" "$T/var/db/repos" "$T/var/cache"/* \
          "$T/etc/portage" "$T/usr/share/portage"

# ---- 3. runtime-useless residue ---------------------------------------------------
# -path .../var/lib/flatpak -prune: this sweep predates any Flatpak app shipping a stray *.la of
# its own, and finding one now (see the assertion below) means it silently deleted whatever
# matched inside Flatpak payloads on every build before this comment, unnoticed because deletion
# runs before the assertion ever gets a chance to see the file. Flatpak app content is
# third-party binary data outside the toolchain-free guarantee's scope (plan/06) — this pipeline
# neither built it nor should be editing it after the fact.
# Two-stage rather than "-prune -o ... -delete" in one expression: -delete implies -depth, and
# GNU find refuses to combine -depth with -prune ("prune does nothing when -depth is in
# effect") — this is the standard find gotcha, not a stylistic choice.
find "$T" -xdev -path "$T/var/lib/flatpak" -prune -o -name '*.la' -print0 2>/dev/null \
  | xargs -0 --no-run-if-empty rm -f --
# Static archives. This used to read `find "$T/usr/lib64" -maxdepth 1`, and that missed 22 MiB
# in three places, all of them one directory deeper than it looked or in the other libdir:
# /usr/lib64/glibc-2.43/libm-2.43.a, /usr/lib/llvm/22/lib64/*.a (11.5 MiB — section 3a below
# removes that slot's include/share/bin but never its archives), and the whole 32-bit multilib
# set under /usr/lib and /usr/lib/gcc/*/*/32. A .a is a link-time input and can never be loaded
# at runtime, so there is no depth or libdir at which one is legitimate in this image; the scope
# is the two libdirs and the depth is unlimited. Asserted in section 4.
find "$T/usr/lib64" "$T/usr/lib" -xdev -name '*.a' -delete 2>/dev/null || true
find "$T/usr/lib/modules" -maxdepth 2 \( -name build -o -name source \) -exec rm -rf {} + 2>/dev/null || true
# ...and the tree those two symlinks POINTED AT. sys-kernel/gentoo-kernel-bin ships a full
# configured kernel source + build tree at /usr/src/linux-<kver>-gentoo-dist-bin so out-of-tree
# modules can be compiled against it. This image has no compiler and a read-only /usr, and its
# only out-of-tree module — the nvidia GSP driver — is built at IMAGE BUILD time by stage 30
# (nvidia-drivers[dist-kernel]), so nothing at runtime can or does read it. It was 145,752 file
# entries, 31.5% of everything in the EROFS: invisible to the prune precisely because the line
# above removes the symlinks that name it, and nothing else ever looked in /usr/src.
rm -rf -- "${T:?}/usr/src"
rm -rf -- "${T:?}/boot"/* 2>/dev/null || true  # UKI lives on the ESP; image /boot stays empty
find "$T" -xdev -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

# locale trim: keep LOCALES_KEEP prefixes (en also keeps en_GB etc.)
#
# LOCALES_KEEP IS NO LONGER A STRING IN build.conf. load_config() derives it from
# config/languages.conf — the same table that produced /etc/locale.gen, so the catalogs kept here
# and the locales compiled there are one list by construction rather than two that agreed for as
# long as nobody edited one of them (plan/22 §2b). The matching below is unchanged, including its
# deliberate looseness: keeping "pt" for a pt_BR row also keeps pt_PT, which is what the comment
# above has always meant by "prefixes".
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

# firmware and microcode classes outside the desktop/laptop scope.
#
# This loop used to live here and ONLY here, which is what plan/10 recorded as its one unclosed
# finding: stage 40 builds the initrd before this stage runs, so the prune list reached the root
# filesystem and never the UKI. Every 0.2.1 machine carried the full qcom ARM SoC tree on its ESP
# and re-downloaded it with every A/B update. The deletion now happens in stage 40 immediately
# before dracut (section 2c); the call here is the idempotent guard that keeps `--from 50` — and
# every assertion below — meaning what it says.
prune_hardware_trees "$T"

# ...and now that the UKI exists and carries the early cpio, the microcode has no second reader.
# /usr/lib/firmware/{intel,amd}-ucode is consulted at exactly one moment in this image's life:
# stage 40 packing it into the UKI. The kernel loads microcode from that early cpio, before any
# filesystem is mounted; the only thing that would ever read the root filesystem's copy is a late
# reload through /sys/devices/system/cpu/microcode/reload, which nothing here does, and fwupd is
# not installed. 13 MiB after the signature prune, and it compresses poorly — microcode is
# already-compact binary, so this is nearly a megabyte of EROFS per megabyte deleted.
#
# THE ORDERING HAZARD THIS CREATES is real and is covered where it bites: a later
# `build.sh --from 40` would run dracut against a target this stage already stripped and produce
# a UKI with an empty early cpio — booting fine, and silently unpatched on every CPU. Stage 40
# asserts GenuineIntel.bin and AuthenticAMD.bin are in the initrd it just built, so that path
# fails loudly instead.
if [[ -d $T/usr/lib/firmware/intel-ucode || -d $T/usr/lib/firmware/amd-ucode ]]; then
  log "removing CPU microcode from the root filesystem (the UKI's early cpio is the only reader)"
  rm -rf -- "$T/usr/lib/firmware/intel-ucode" "$T/usr/lib/firmware/amd-ucode"
fi

# dev files: headers, pkg-config/cmake metadata, GIR XML, vala bindings. This used to be an
# INSTALL_MASK in the target make.conf, but that leaked onto the builder root and broke build
# deps there (see the note in config/portage/make.conf.in) — done here it touches only $TARGET.
# NB: usr/lib64/girepository-1.0 (the binary typelibs) USED to be deliberately kept here,
# because gjs and gnome-shell loaded them at runtime. That exception is withdrawn with GNOME:
# make.conf.in now sets USE=-introspection globally, so most of these should not be built in
# the first place, and nothing in a Plasma image loads a typelib. The directory is deleted as
# a guard against the ones dev-libs/glib still builds (it keeps introspection as a per-package
# line) — pure dead weight once nothing reads them.
# ROLLBACK: this line and the global -introspection move together. Putting the flag back means
# taking girepository-1.0 out of this list again.
#
# usr/share/help was GNOME's yelp documentation. Nothing installs there now, but the line stays
# as a cheap guard — KDE's equivalent is the per-app DocBook handbook, which lands in
# /usr/share/doc/HTML and is therefore already covered by the usr/share/doc entry. USE=-handbook
# should mean there is nothing there to cover in the first place.
for d in usr/include usr/share/doc usr/share/info usr/share/man usr/share/gtk-doc \
         usr/share/devhelp usr/share/aclocal usr/lib64/pkgconfig usr/share/pkgconfig \
         usr/lib64/cmake usr/share/gir-1.0 usr/share/vala usr/share/zsh usr/share/help \
         usr/lib64/girepository-1.0; do
  rm -rf -- "${T:?}/$d"
done

# (The VTE demo-app deletion that used to live here is gone with GNOME. gui-libs/vte was in the
# image only because gui-apps/gnome-console linked libvte, and Gentoo's vte ebuild shipped
# upstream's demo terminal alongside it — a second, unbranded terminal registered in
# /usr/share/xdg-terminals. kde-apps/konsole has no equivalent, and gui-libs/vte is masked
# outright in package.mask/image, so there is nothing left to delete. The assertions in
# section 4 changed with it.)

# ---- 3a. LLVM: keep libLLVM.so (mesa), drop the rest ---------------------------------
# llvm-core/llvm is a hard dep of media-libs/mesa — radeonsi and llvmpipe dlopen libLLVM.so —
# so the library stays. Everything else does not: LLVM installs under /usr/lib/llvm/<slot>/
# rather than the standard prefixes, so its 14,766 headers, 582 binaries and man pages sailed
# past the usr/include / usr/share/man rules above AND past the section-4 banned-binary sweep
# (which only looks at maxdepth 1 in /usr/bin and friends). That left llc, lli, opt, bugpoint
# and clang-offload-packager — LLVM's code generators — in an image whose whole premise is that
# it has no toolchain. The assertions in section 4 are widened to cover this directory.
for slot in "$T"/usr/lib/llvm/*/; do
  [[ -d $slot ]] || continue
  rm -rf -- "$slot"/{include,share,bin} "$slot"/lib64/cmake
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

  # ...and the runtimes NOTHING in the image links. "Keep the gcc runtime" above was never meant
  # to mean all of it: a DT_NEEDED sweep over /usr/lib64, /usr/bin and /usr/sbin counts 1159
  # references to libstdc++.so.6, 147 to libgcc_s.so.1 and 3 to libgomp.so.1 — and ZERO to each
  # of the ten below, which are the sanitizer, Fortran, transactional-memory and OpenMP-offload
  # runtimes. They are 8.6 MiB of libraries that only a program compiled against them could ever
  # load, in an image with no compiler. libatomic.so.1 also has no references but stays: it is
  # 34 KB and glibc's atomics fallback is the kind of thing a future package picks up silently.
  for l in libgfortran libasan libtsan libhwasan liblsan libubsan libquadmath libitm libcc1 \
           libgomp-plugin-nvptx; do
    rm -f -- "$GCC_LIBDIR/$l".so*
  done

  # The 32-bit multilib half of gcc, 31 MiB. See the multilib block in 3d for why the whole
  # 32-bit ABI is dead weight here; this is the part of it that gcc owns. It survived until now
  # because the *.a sweep two lines up is -maxdepth 1 and this is one level deeper.
  rm -rf -- "$GCC_LIBDIR/32"

  # the loader must still find libstdc++/libgcc_s
  ls "$T"/etc/ld.so.conf.d/*gcc* >/dev/null 2>&1 \
    || warn "no gcc ld.so.conf.d entry — libstdc++ may be unfindable at runtime"
  # ...and must not be told to search a directory that no longer exists. ldconfig tolerates a
  # missing path silently, so this is tidiness rather than a fix — but a stale path in
  # ld.so.conf.d is exactly the sort of thing that makes a later "why is this not found?"
  # investigation take an hour.
  sed -i '\|/32$|d' "$T"/etc/ld.so.conf.d/*gcc* 2>/dev/null || true
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

# podman[wrapper] (plan/13) ships this tmpfiles snippet to symlink /run/docker.sock at
# /run/podman/podman.sock — the ROOTFUL API socket, which this image's preset disables and
# nothing ever starts. The /usr/bin/docker wrapper script is kept (it execs podman directly and
# works fine rootless); only the socket symlink goes. A path that exists and refuses every
# connection is a worse failure than one that is simply absent: it makes a client report
# "permission denied"/"connection refused" instead of "docker is not running".
rm -f -- "$T/usr/lib/tmpfiles.d/podman-docker.conf"
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

# ---- 3d. multilib: the 32-bit ABI has no users in this image --------------------------
# On amd64 /usr/lib is the 32-bit libdir and /usr/lib64 the 64-bit one. sys-libs/glibc and
# sys-devel/gcc are built multilib by the profile, so a complete 32-bit runtime is installed —
# ld-linux.so.2, libc.so.6, the NSS modules, the crt*.o startup files — and NOTHING in the image
# can load any of it: a DT_NEEDED/ELF-class sweep over /usr/lib64, /usr/bin and /usr/sbin finds
# zero ELFCLASS32 objects. 32-bit Flatpaks carry their own org.freedesktop.Platform.Compat.i386
# runtime and never look at the host's. Together with the gcc half above this is 42.7 MiB.
#
# The alternative fix is `sys-libs/glibc -multilib` + `sys-devel/gcc -multilib` in
# package.use/image, which never builds it at all and saves build time too. It is not taken here
# because both are @system packages on a multilib profile, and a mis-set flag on glibc is
# discovered at the far end of a multi-hour rebuild. Deleting is exact and costs nothing.
#
# CAREFUL: this deletes by FILE CONTENT, not by name or by directory. /usr/lib holds real, live
# things at the same depth — os-release (systemd reads it, /etc/os-release is a symlink to it),
# the terminfo symlink, and the firmware/modules/systemd/udev/python trees below. Two content
# tests, and nothing else goes:
#
#   ELFCLASS32  — \x7fELF\x01 in the first five bytes. The libraries, the loader, the crt*.o
#                 startup files. A 64-bit consumer cannot link or load one of these by
#                 construction, which is what makes deleting by class safe rather than merely
#                 well-researched.
#   GNU ld script — /usr/lib/libc.so is not an ELF at all but a text stanza reading
#                 `OUTPUT_FORMAT(elf32-i386) GROUP ( /lib/libc.so.6 ... )`. It is consumed only
#                 by ld at link time. Testing only the ELF class leaves it behind, and then the
#                 section-4 assertion for 32-bit residue trips on this stage's own output.
#
# Dangling symlinks left pointing at any of it are swept in 3e.
is_elf32()     { [[ "$(od -An -tx1 -N5 -- "$1" 2>/dev/null | tr -d ' ')" == 7f454c4601 ]]; }
is_ld_script() { [[ "$(head -c 16 -- "$1" 2>/dev/null)" == '/* GNU ld script'* ]]; }
n32=0
while IFS= read -r -d '' f; do
  is_elf32 "$f" || is_ld_script "$f" || continue
  rm -f -- "$f" && n32=$((n32 + 1))
done < <(find "$T/usr/lib" -maxdepth 1 -type f -print0 2>/dev/null)
log "multilib: removed $n32 32-bit objects from /usr/lib"
# /usr/lib/cpp -> /usr/bin/x86_64-pc-linux-gnu-cpp: the preprocessor driver the split above
# deletes. The section-4 banned-binary sweep looks in /usr/bin, /usr/sbin, /bin and /sbin, so a
# `cpp` living in /usr/lib was never going to trip it — it is a symlink, not a binary, but it is
# the last thing in the image still spelling the name of a compiler driver.
rm -f -- "$T/usr/lib/cpp"

# ---- 3e. dangling symlinks this stage's own deletions create --------------------------
# Deliberately NOT a whole-image sweep: several symlinks in this image are supposed to dangle at
# build time and are asserted to exist below — /etc/resolv.conf points into /run, /etc/mtab into
# /proc — so a blanket "delete every broken link" would break the image and the assertions with
# it. Only the two directories this stage empties are swept.
#
#   /usr/lib/modules/<kver>/: gentoo-kernel-bin ships config, vmlinuz and System.map as symlinks
#     into /usr/src/linux-<kver>-gentoo-dist-bin, and section 3 deletes that tree. The `build`
#     and `source` links were already handled by name; these three were not, and a dangling
#     `vmlinuz` under /usr/lib/modules is the kind of thing kernel-install and dracut follow.
#   /usr/lib (maxdepth 1): the ABI-mate symlinks of the 32-bit libraries just deleted
#     (libm.so -> ../../lib/libm.so.6 and ~20 more).
prune_dangling_links() {
  local dir=$1 depth=$2 link tgt base
  [[ -d $dir ]] || return 0
  while IFS= read -r -d '' link; do
    tgt="$(readlink -- "$link")"
    if [[ $tgt == /* ]]; then
      [[ -e "$T$tgt" ]] && continue          # absolute: resolve inside the image, not the builder
    else
      base="$(dirname -- "$link")"
      [[ -e "$base/$tgt" ]] && continue
    fi
    log "removing dangling symlink: ${link#"$T"} -> $tgt"
    rm -f -- "$link"
  done < <(find "$dir" -maxdepth "$depth" -type l -print0 2>/dev/null)
}
prune_dangling_links "$T/usr/lib/modules" 2
prune_dangling_links "$T/usr/lib" 1

# ---- 3f. kernel modules that are dead by construction ---------------------------------
# RUNS AFTER 3e ON PURPOSE. depmod at the end of this section reads the module directory, and
# until 3e has swept them that directory still holds three symlinks pointing into the /usr/src
# tree section 3 deleted. depmod survives them — it exits 0 — but prints three
# "ERROR: fstatat(3, System.map): No such file or directory" lines into the build log, which is
# exactly the kind of alarming-but-meaningless output that costs someone an hour later. Ordering
# this after the sweep also means depmod indexes the tree in its final shape.
#
# NOT a general module prune. plan/11 deliberately leaves that out of scope — the module tree is
# 623 MiB and a class-based cut of it (InfiniBand, DVB tuners, enterprise NICs) is a bigger
# surface than this change wants. Everything below is a module that CANNOT load on this image,
# not one that is merely unlikely to:
#
#   nouveau.ko (+ mxm-wmi.ko, which nothing else in the tree pulls) — x11-drivers/nvidia-drivers
#     blacklists nouveau unconditionally in /etc/modprobe.d/nvidia.conf, VIDEO_CARDS no longer
#     builds for it (plan/03), and prune-firmware.txt class 3 has already deleted every GSP blob
#     it would request. It has been out of the initrd since 0.2.2; this is the root filesystem's
#     copy, 7.6 MiB of a driver modprobe refuses to touch.
#   kheaders.ko — CONFIG_IKHEADERS, whose whole job is handing the running kernel's headers to a
#     BPF or systemtap build. plan/06 guarantees there is no compiler to hand them to.
#   the in-kernel selftests — test_bpf, ext4-inode-test, fat_test, the KUnit framework and its
#     helpers: 126 files, 13.4 MiB, loaded only by a test harness no image ships.
#     config/dracut-omit-drivers.txt keeps the same set out of the initrd; the two halves of that
#     decision should move together.
MOD_ROOT="$T/usr/lib/modules"
if [[ -d $MOD_ROOT ]]; then
  # Same "exactly one" guard as stage 40, and for the same reason: with two module trees present
  # this would depmod one of them and leave the other describing files it no longer has.
  mapfile -t KVERS < <(find "$MOD_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  (( ${#KVERS[@]} == 1 )) \
    || die "expected exactly one kernel in $MOD_ROOT, found ${#KVERS[@]}: ${KVERS[*]:-<none>}"
  KVER="${KVERS[0]}"
  n_mod=0
  while IFS= read -r -d '' m; do
    rm -f -- "$m"; n_mod=$((n_mod + 1))
  done < <(find "$MOD_ROOT/$KVER" -type f \
             \( -name 'nouveau.ko*'  -o -name 'mxm-wmi.ko*' -o -name 'kheaders.ko*' \
             -o -name 'test_*.ko*'   -o -name '*-test.ko*'  -o -name '*_test.ko*' \
             -o -name '*kunit*.ko*' \) -print0)
  log "dead modules: removed $n_mod (nouveau, kheaders, in-kernel selftests)"

  # depmod is not optional after deleting modules, and the failure it prevents is a confusing
  # one: modules.dep and modules.alias still name every file that just went, and modprobe turns
  # a stale dependency line into "module not found" for the module that DEPENDED on it rather
  # than for the one actually missing. Regenerate against the target root so the indexes describe
  # what ships. (-b resolves $T/lib/modules, which is the merged-/usr symlink seed_merged_usr
  # created, so this reads the same tree that was just pruned.)
  require_cmds depmod
  depmod -b "$T" "$KVER" || die "depmod failed after the dead-module prune"
fi

# ---- 3g. Qt D-Bus Viewer: the one menu entry USE could not take away -------------------
# config/portage/package.use/image explains at length why dev-qt/qttools ships with BOTH qdbus
# (plasma-workspace RDEPENDs it) and widgets (kwin RDEPENDs it), and that the combination builds
# qdbusviewer whether this image wants it or not. USE is resolved once per package, so there is
# no flag that keeps qdbus for plasma-workspace while dropping the GUI debugger — the only place
# left to act is here, after the package is merged.
#
# What it is: a Qt-branded D-Bus object browser (Name=Qt D-Bus Viewer, Categories=Development;
# Debugger;) that lands in the application menu of an image whose users are not debugging Qt
# applications — the same "developer tool with no audience on this image" case already made for
# Qt Assistant and Qt Linguist, which USE=-assistant -linguist does handle.
#
# The whole app goes, not just its .desktop file: the binary is unreachable from the menu once
# the entry is gone, and nothing in the pinned tree RDEPENDs qdbusviewer (qttools' only mention
# of it is the "widgets? ( !dev-qt/qdbusviewer:5 )" slot blocker). qdbus — the CLI tool
# plasma-workspace actually asked for — is a DIFFERENT binary and is deliberately left alone.
#
# /usr/bin/qdbusviewer6 is a relative symlink into /usr/lib64/qt6/bin and must be named here:
# section 3e sweeps /usr/lib/modules and /usr/lib only, so a dangling link in /usr/bin would
# survive to ship.
if [[ -e $T/usr/share/applications/qdbusviewer.desktop ]]; then
  log "removing the Qt D-Bus Viewer app (menu entry, icon and binary) — see package.use/image"
  rm -f -- "$T/usr/share/applications/qdbusviewer.desktop" \
           "$T/usr/share/icons/hicolor/128x128/apps/qdbusviewer.png" \
           "$T/usr/bin/qdbusviewer6" \
           "$T/usr/lib64/qt6/bin/qdbusviewer"
fi

# ---- 3h. Qt Linguist: the second menu entry USE could not take away --------------------
# Same shape as 3g, different cause, and narrower: this only ever finds anything on the
# INSTALLER profile. config/portage/package.use/profile.installer turns dev-qt/qttools' linguist
# flag on for that profile alone, because Calamares' exported CalamaresConfig.cmake hardcodes
# LinguistTools into the REQUIRED Qt6 component list that every consumer of the Calamares CMake
# package must satisfy — and <id>-calamares-accounts is such a consumer. The flag is needed for
# /usr/lib64/cmake/Qt6LinguistTools to exist at BUILD time; the GUI it also builds is not
# wanted at RUN time. On desktop and console the flag is off, nothing here exists, and both the
# deletion and its assertions below are no-ops — which is itself worth keeping, since they would
# catch the flag leaking back into a shared file.
#
# What it is: Qt Linguist (Name=Qt Linguist, a translation-file editor for Qt application
# developers) — the same "developer tool with no audience on this image" case section 3g makes
# for the D-Bus viewer, and the case package.use itself made for Qt Assistant.
#
# lrelease/lupdate are deliberately NOT touched: they are CLI tools, not menu entries, and this
# section is about what a user of the image can launch — the same line 3g draws when it deletes
# the viewer and leaves qdbus alone.
#
# /usr/bin/linguist6 is a relative symlink into /usr/lib64/qt6/bin and must be named here for
# the reason spelled out in 3g: section 3e sweeps /usr/lib/modules and /usr/lib only, so a
# dangling link in /usr/bin would survive to ship.
if [[ -e $T/usr/share/applications/linguist.desktop ]]; then
  log "removing the Qt Linguist app (menu entry, icon and binary) — see package.use/profile.installer"
  rm -f -- "$T/usr/share/applications/linguist.desktop" \
           "$T/usr/share/icons/hicolor/128x128/apps/linguist.png" \
           "$T/usr/share/metainfo/io.qt.Linguist.metainfo.xml" \
           "$T/usr/bin/linguist6" \
           "$T/usr/lib64/qt6/bin/linguist"
fi

# ---- 3i. wallpapers, on live media only (plan/20) --------------------------------------
# 255 MiB of PNG and JPEG, and the most expensive tree in this image per byte DOWNLOADED: it
# compresses at 99%, so unlike almost everything else here the installed cost and the shipped
# cost are the same number (plan/10 §5 measured 256 MiB installed against 254 MiB of EROFS).
#
# The set already dropped the larger half: kde-plasma/plasma-workspace-wallpapers is `#not-live`
# in config/portage/sets/desktop, so on a live profile it is never emerged and 216.8 MiB never
# reaches the target at all — which is strictly better than deleting it here, because the atom
# also leaves installer.lock and the package audit.
#
# What is left is Breeze's own `Next`, 38.3 MiB, and THAT is why this section exists: it comes
# from kde-plasma/breeze, which also carries the widget style, the colour scheme, the window
# decoration and the look-and-feel fallback the whole session resolves through. There is no USE
# flag for it and no dropping the package, so a file deletion is the only lever.
#
# LIVE ONLY, and the role is the reason rather than the profile name: a medium that boots once
# to run Calamares and is then thrown away is the one case where a desktop background is worth
# less than the 255 MiB it costs on the stick. The product keeps every wallpaper it has — the
# desktop lock and expected-packages list are untouched by this change.
#
# ONE EXCEPTION, AND IT IS NOT A HOLE IN THE RULE. Stage 40 installs a single wallpaper package of
# this image's own — $DISTRO_ID, 0.4 MiB, from config/calamares/system/wallpaper — and this
# section deletes around it rather than over it. That is what changed when the medium stopped
# using the solid-colour plugin: org.kde.image needs an image, and the cheapest correct one is
# the brand mark the boot splash has already shown twice. The saving is 254.4 of the 255 MiB, so
# the exception costs 0.15% of it.
#
# It is a DENYLIST-BY-EXCLUSION rather than a `rm -rf` of two named packages, and that direction
# matters: a new wallpaper arriving in the closure — breeze picking up a second one, or a
# dependency that ships artwork — is silently kept by a named-target deletion and silently dropped
# by this one. The saving should not depend on this comment staying current.
#
# The containment names that package explicitly, in the live medium's layout script, because
# org.kde.image with an unresolvable image is an empty desktop rather than a plain one. Deleting
# the rest and NOT naming what is left is the one combination that produces a visibly broken
# session, so the assertion in section 4 checks both halves together.
if [[ $PROFILE_ROLE == live ]]; then
  if [[ -d $T/usr/share/wallpapers ]]; then
    wp_mib=$(du -xsm "$T/usr/share/wallpapers" 2>/dev/null | cut -f1)
    # -mindepth/-maxdepth 1: wallpaper packages are directories directly under this one, and
    # nothing else belongs here. `! -name` on the one we keep, so the deletion is defined by what
    # survives rather than by a list of what goes.
    find "$T/usr/share/wallpapers" -mindepth 1 -maxdepth 1 ! -name "$DISTRO_ID" \
         -exec rm -rf -- {} +
    wp_left_mib=$(du -xsm "$T/usr/share/wallpapers" 2>/dev/null | cut -f1)
    log "live profile ($BUILD_PROFILE): /usr/share/wallpapers pruned to the $DISTRO_ID package
  alone (${wp_mib:-?} -> ${wp_left_mib:-?} MiB) — the desktop containment and the lock screen
  both name it by path on this medium"
  fi
fi

# ---- 3j. GRUB, on live media only (plan/20 §4.1) ---------------------------------------
# 68.4 MiB installed, 41.6 MiB of EROFS, and not one byte of it is ever executed.
#
# sys-boot/grub is in this closure because it is an UNCONDITIONAL RDEPEND of app-admin/calamares
# — there is no USE flag for it and no dropping the package, so this is a file deletion for the
# same reason section 3i is. config/portage/sets/installer already calls the whole tail out
# ("a UKI-booting, systemd-boot, EROFS distro has no use whatsoever for GRUB"), and
# config/calamares/modules/imagebootloader.conf.in says the operative half out loud: GRUB "is on
# this medium only because it is an unconditional RDEPEND of app-admin/calamares, and it is
# never run."
#
# Verified rather than assumed, in both directions it could be wrong:
#
#   1. THE MEDIUM DOES NOT BOOT FROM IT. Stage 60 builds this image with an ESP carrying
#      systemd-boot and a UKI, exactly as it does for the product.
#   2. THE INSTALL DOES NOT USE IT. config/calamares/settings.conf.in's exec: sequence names
#      `imagebootloader`, our own module, and never the stock `bootloader` or `grubcfg`.
#      Installing a bootloader here is four file copies onto the target ESP.
#
# /usr/bin only for the binaries: /usr/sbin is a SYMLINK to bin in this image, so the 27 tools
# appear at both paths and are one set of inodes. (This is also why the first measurement of
# this tree read 83.5 MiB — `find` walked both and counted every binary twice.)
#
# i386-pc is worth naming on its own: 16.3 MiB of legacy-BIOS platform modules, on a distro
# that boots UEFI only and could not use them on any machine it supports.
#
# NOT deleted: app-admin/os-prober, whose only caller is the /etc/grub.d/30_os-prober snippet
# being removed here, and /usr/libexec/libostree/grub2-15_ostree, which is ostree's file rather
# than GRUB's. Both measure 0.0 MiB. Deleting a package's contents for no bytes buys nothing
# except one more path that can silently stop matching.
if [[ $PROFILE_ROLE == live ]]; then
  if [[ -d $T/usr/lib/grub || -e $T/usr/bin/grub-install ]]; then
    grub_mib=$(du -xscm "$T/usr/lib/grub" "$T/usr/share/grub" 2>/dev/null | tail -n1 | cut -f1)
    log "live profile ($BUILD_PROFILE): removing GRUB (${grub_mib:-?} MiB of platform modules
  and data, plus 27 tools and the /etc snippets). It is an unconditional RDEPEND of calamares
  and is never run — the medium boots a UKI and the install writes systemd-boot (plan/20 §4.1)"
    rm -rf -- "$T/usr/lib/grub" "$T/usr/share/grub" "$T/etc/grub.d"
    rm -f  -- "$T/etc/default/grub"
    find "$T/usr/bin" -maxdepth 1 -name 'grub-*' -delete
  fi
fi

# ---- 3k. the Emoji Selector, on live media only -----------------------------------------
# 0.4 MiB, and this section is NOT about the bytes — it is section 3g's argument, one audience
# further out. 3g and 3h delete the Qt D-Bus Viewer and Qt Linguist because a developer tool has
# no audience on this image; this deletes an emoji picker because it has no audience on a medium
# whose entire session is one installer, one language picker and a disk chooser. There is nowhere
# on a live stick to paste an emoji INTO.
#
# It reaches the image inside kde-plasma/plasma-desktop, which is the desktop itself, so there is
# no set marker and no USE flag — a file deletion is the only lever, the same position 3i and 3j
# are in. Confirmed against the pinned tree's own binary package rather than inferred from the
# ebuild, which never mentions it: plasma-desktop-6.6.6 ships /usr/bin/plasma-emojier, the QML
# plugin under org/kde/plasma/emoji, and TWO descriptors of the same name.
#
# BOTH DESCRIPTORS, because they do different jobs and deleting one leaves the feature half
# present. /usr/share/applications is the launcher entry ("Emoji Selector", which is what a user
# sees in Kickoff); /usr/share/kglobalaccel is the global-shortcut registration, and a kglobalaccel
# descriptor whose Exec no longer exists is a shortcut that fails silently rather than one that is
# gone. The same line 3g draws between a menu entry and a binary, drawn twice here.
#
# The QML plugin goes with it and takes nothing else: org/kde/plasma/emoji is imported by no file
# in the target outside its own qmldir and typeinfo — checked, because Plasma's virtual keyboard
# and the input-method panel were the plausible second consumers and neither is one.
#
# The .mo files are included, unlike the 0.0 MiB tails section 3j deliberately leaves alone. They
# are named for the binary rather than for a package, so `emojier` is the whole predicate and the
# sweep cannot quietly start matching something else — which is the property that made 3j's
# leave-it-alone rule right there and makes the opposite right here.
if [[ $PROFILE_ROLE == live ]]; then
  if [[ -e $T/usr/share/applications/org.kde.plasma.emojier.desktop ]]; then
    log "live profile ($BUILD_PROFILE): removing the Emoji Selector (menu entry, global-shortcut
  descriptor, binary and QML plugin) — plasma-desktop ships it and a medium that runs one
  installer has nothing to paste an emoji into"
    rm -f  -- "$T/usr/share/applications/org.kde.plasma.emojier.desktop" \
              "$T/usr/share/kglobalaccel/org.kde.plasma.emojier.desktop" \
              "$T/usr/bin/plasma-emojier"
    rm -rf -- "$T/usr/lib64/qt6/qml/org/kde/plasma/emoji"
    find "$T/usr/share/locale" -name 'org.kde.plasma.emojier.mo' -delete
  fi
fi

# ---- 3m. /usr/share/i18n/SUPPORTED, on the installer medium only (plan/22 §6) --------------
#
# THIS USED TO BE A DELETION THAT CHANGED A UI. Calamares' `locale` module reads
# /usr/share/i18n/SUPPORTED FIRST and only falls back to localeGenPath
# (modules/locale/Config.cpp:51). That file is glibc's list of every locale glibc CAN build —
# roughly five hundred — while this image compiles exactly the nine in config/languages.conf, so
# the stock locale dialog offered `en_CA.UTF-8` and hundreds of others of which the machine being
# installed could load nine. Removing the file made loadLocales() fall through to /etc/locale.gen,
# which stage 40 writes from the same table, and the dialog then listed what the target could load.
#
# THE PAGE THAT READ IT IS GONE (plan/28 §6). `location` replaced the stock `locale` module and
# asks for a place rather than a locale — the language page already chose the language — so
# nothing on this medium consults SUPPORTED any more and the deletion changes no UI at all.
#
# IT STAYS, and the reason is now the plain one: 22 KiB of a list this image cannot act on, on a
# medium that is booted once and thrown away. The line is kept rather than dropped because the
# file has a way of becoming load-bearing again — anything that shells out to `locale -a`, or a
# future page that offers formats, would find five hundred entries where the image has nine.
#
# LIVE PROFILES ONLY, and the distinction is not cosmetic: on an installed system this file is
# glibc's own data and nothing here is entitled to an opinion about it.
if [[ $PROFILE_ROLE == live ]]; then
  if [[ -e $T/usr/share/i18n/SUPPORTED ]]; then
    log "live profile ($BUILD_PROFILE): removing /usr/share/i18n/SUPPORTED — this image compiled
  nine locales and that file lists five hundred it cannot load (plan/22 §6, plan/28 §6)"
    rm -f -- "$T/usr/share/i18n/SUPPORTED"
  fi
fi

# ---- 3n. IBM Plex: keep the two faces the installer renders (plan/28) -------------------
#
# media-fonts/ibm-plex is on the installer medium and nowhere else (config/portage/sets/installer)
# because the Calamares pages set their type from the design system: IBM Plex Sans for the UI and
# IBM Plex Mono for device paths, sizes and version strings. The package ships eleven families —
# Serif, Condensed, the variable Roman/Italic pair, and the Arabic, Devanagari, Hebrew, Korean and
# two Thai scripts — of which this image renders exactly two.
#
# MEASURED in the target root on 2026-09-18, because the first version of this section estimated
# from the distfile and the estimate was wrong in both directions. The installed tree is 58 MiB,
# not ~150: 41 MiB of it is the Korean family alone, and Sans and Mono together are 5. So this
# saves about 53 MiB — real, and smaller than the comment used to claim.
#
# AND THE FILES ARE NOT WHERE THE FIRST VERSION LOOKED. font.eclass installs each family into a
# subtree of its own, two more levels down than a flat fonts directory:
#
#     ibm-plex/IBM-Plex-Sans/fonts/complete/ttf/IBMPlexSans-Regular.ttf
#     ibm-plex/IBM-Plex-Sans-KR/fonts/complete/ttf/{hinted,unhinted}/IBMPlexSansKR-Regular.ttf
#
# so the `find -maxdepth 1` this section shipped with matched nothing, deleted nothing, and tripped
# the zero-deletions assertion below on the first build that ever ran it. That is the assertion
# doing its job rather than a bug getting through: without it the medium would have carried all
# 53 MiB while the log said the prune had happened.
#
# THE RULE IS STATED POSITIVELY, which is the whole point: everything that is not IBMPlexSans-* or
# IBMPlexMono-* goes. Listing the families to DELETE would be a list that silently stops matching
# the day upstream adds a twelfth script — the failure mode section 3i's comment warns about —
# whereas a keep-list can only ever fail in the direction that is loud, because the assertion
# below requires both kept families to still be there afterwards. The HYPHEN is what makes the
# keep-list precise, and it is doing more work than it looks: IBMPlexSansCondensed-Regular.ttf
# does not match IBMPlexSans-*, and neither does IBMPlexSansArabic-, IBMPlexSansKR-,
# IBMPlexSansThai- or IBMPlexSansVar-. Drop the hyphen and this prune keeps everything.
#
# NOT the CJK question. media-fonts/noto-cjk is a separate atom with its own INCLUDE_CJK_FONTS
# switch, and it is what renders 日本語 on the language page. Plex's own Korean family is dropped
# here because Noto already covers that script for every application on the medium, not because
# the medium stopped caring about it.
IBM_PLEX_DIR="$T/usr/share/fonts/ibm-plex"
if [[ -d $IBM_PLEX_DIR ]]; then
  plex_dropped=0
  while IFS= read -r -d '' f; do
    b="$(basename -- "$f")"
    case $b in
      IBMPlexSans-*|IBMPlexMono-*) continue ;;
    esac
    rm -f -- "$f"
    plex_dropped=$(( plex_dropped + 1 ))
  done < <(find "$IBM_PLEX_DIR" -type f \( -name '*.ttf' -o -name '*.otf' \) -print0)

  # Each dropped family leaves its subtree behind holding fonts.dir, fonts.scale and
  # encodings.dir — X11 core-font indexes that now name nothing at all. Remove any family
  # directory with no font left in it and those go with it, which is why this section does not
  # need to run mkfontscale in the target. The two KEPT families are untouched by both loops:
  # nothing inside IBM-Plex-Sans or IBM-Plex-Mono matches the drop rule, so their own indexes
  # are still accurate for every file still there.
  while IFS= read -r d; do
    if [[ -z $(find "$d" -type f \( -name '*.ttf' -o -name '*.otf' \) -print -quit) ]]; then
      rm -rf -- "$d"
    fi
  done < <(find "$IBM_PLEX_DIR" -mindepth 1 -maxdepth 1 -type d)

  # Both halves are asserted, and they fail for opposite reasons. Zero deletions means the
  # filenames or the directory layout changed shape and this section has quietly become a no-op
  # that still claims 53 MiB — which is precisely what happened on 2026-09-18. Zero survivors
  # means the keep-patterns stopped matching and the installer just lost its typeface, which
  # renders as Calamares falling back to whatever fontconfig substitutes, on every page.
  plex_kept="$(find "$IBM_PLEX_DIR" -type f -name 'IBMPlex[SM]*' | wc -l)"
  (( plex_dropped > 0 )) || die "no IBM Plex face matched the drop rule in $IBM_PLEX_DIR. The
  package installs eleven families and this image renders two, so matching none means the faces
  are no longer <Family>/fonts/complete/ttf/IBMPlex<Family>-<Weight>.ttf and this section is
  saving nothing."
  (( plex_kept > 0 )) || die "the IBM Plex prune removed every face in $IBM_PLEX_DIR. The installer
  sets its type to 'IBM Plex Sans' and 'IBM Plex Mono' by name (config/calamares/qml/Theme.qml),
  so it would come up in whatever fontconfig substitutes, on every page, with nothing in the log."
  log "installer medium: dropped $plex_dropped IBM Plex face(s), kept $plex_kept (Sans and Mono)"
fi

# ---- 4. THE ASSERTIONS (build fails if any trips) ------------------------------------
fail=0
violation() { warn "PRUNE VIOLATION: $*"; fail=1; }

# NB: python/python3 are deliberately NOT in this list — see the interpreter note below.
# NB: /usr/lib/llvm is searched WITHOUT -maxdepth, unlike the standard bin dirs. LLVM installs
# into /usr/lib/llvm/<slot>/bin/, which is why llc, lli, opt and clang-offload-packager shipped
# undetected until section 3a started deleting that tree — the sweep below is what keeps them
# from coming back the next time a mesa bump changes the llvm slot.
for b in gcc g++ cc c++ cpp ld as ar make cmake ninja meson cargo rustc \
         clang clang++ llc lli opt llvm-as llvm-link \
         emerge ebuild portageq pip; do
  hits="$(find "$T/usr/bin" "$T/usr/sbin" "$T/bin" "$T/sbin" \
            -maxdepth 1 \( -name "$b" -o -name "$b-*" \) 2>/dev/null || true)"
  hits+="$(find "$T/usr/lib/llvm" \( -name "$b" -o -name "$b-*" \) 2>/dev/null || true)"
  [[ -n $hits ]] && violation "toolchain/interpreter binary present: $hits"
done

[[ -e $T/usr/include && -n $(ls -A "$T/usr/include" 2>/dev/null) ]] && violation "/usr/include not empty"
[[ -e $T/usr/src && -n $(ls -A "$T/usr/src" 2>/dev/null) ]] && violation "/usr/src not empty (kernel build tree came back)"
# The desktop the user actually gets. Every one of these is invisible to stage 70 — it reads a
# serial port, so an image pruned down to a black screen still reports green — and every one
# fails differently: no shell, no file manager, no session, no way to log in.
if profile_has_set desktop; then
  [[ -x $T/usr/bin/konsole ]]             || violation "konsole missing after prune"
  [[ -x $T/usr/bin/dolphin ]]             || violation "dolphin missing after prune"
  [[ -x $T/usr/bin/plasmashell ]]         || violation "plasmashell missing after prune"
  [[ -x $T/usr/bin/startplasma-wayland ]] || violation "startplasma-wayland missing after prune"
  [[ -x $T/usr/bin/plasmalogin || -x $T/usr/sbin/plasmalogin ]] \
    || violation "plasma-login-manager missing after prune — no way to log in"
  [[ -f $T/usr/share/wayland-sessions/plasma.desktop ]] \
    || violation "plasma.desktop wayland session missing after prune"
  # The cheapest assertion that USE=semantic-desktop actually resolved. The flag is a profile
  # global, so a profile change or a stray -semantic-desktop would silently produce a Plasma
  # image with no file indexer and no error anywhere else.
  # CONFIRMED on the first Plasma build (2026-08-25): the binary is /usr/bin/balooctl6, and
  # plain "balooctl" does not exist. Both spellings stay accepted anyway — the assertion exists
  # to catch a missing indexer, not to pin a filename, and a future KF rename should trip it
  # loudly rather than be silently tolerated by a wildcard.
  [[ -x $T/usr/bin/balooctl6 || -x $T/usr/bin/balooctl ]] \
    || violation "balooctl missing after prune — USE=semantic-desktop did not take, so the image has no file indexer"
  # Section 3g deletes the Qt D-Bus Viewer by path, and a Qt bump that renames any of those
  # paths would make every rm a silent no-op — the entry would simply reappear in the menu with
  # nothing in the log to say so. Assert on the .desktop file (the menu is what this is about)
  # and on the binary, and keep qdbus itself in view: it must SURVIVE, since plasma-workspace's
  # RDEPEND on qttools[qdbus] is the whole reason qdbusviewer got built.
  [[ -e $T/usr/share/applications/qdbusviewer.desktop ]] \
    && violation "qdbusviewer.desktop is back in the menu — section 3g's paths no longer match what qttools installs"
  [[ -e $T/usr/lib64/qt6/bin/qdbusviewer || -e $T/usr/bin/qdbusviewer6 ]] \
    && violation "qdbusviewer binary survived the prune — section 3g deleted the wrong path"
  [[ -x $T/usr/bin/qdbus6 || -x $T/usr/bin/qdbus ]] \
    || violation "qdbus missing after prune — section 3g took the CLI tool plasma-workspace depends on, not just the viewer"
  # Section 3h, same reasoning as 3g: the deletions are by path, so a Qt bump that renames any
  # of them turns every rm into a silent no-op and the entry reappears with nothing in the log.
  [[ -e $T/usr/share/applications/linguist.desktop ]] \
    && violation "linguist.desktop is back in the menu — section 3h's paths no longer match what qttools installs"
  [[ -e $T/usr/lib64/qt6/bin/linguist || -e $T/usr/bin/linguist6 ]] \
    && violation "Qt Linguist binary survived the prune — section 3h deleted the wrong path"
  # Section 3i (plan/20), BOTH directions, because this change can fail in both and neither
  # failure is visible to stage 70 — it reads a serial port, and a desktop that comes up empty
  # reports green.
  #
  # On a live medium the two halves have to agree: exactly one wallpaper left, AND the containment
  # naming it. Either half alone is worse than neither — the collection deleted with nothing named
  # is an empty desktop, and a name that resolves while 255 MiB is still on the stick is the cost
  # without the saving.
  # Section 3m (plan/22 §6), and it is asserted rather than trusted for the same reason the
  # wallpaper is: the symptom of getting it wrong is a page that draws fine and lists the wrong
  # things, which no serial-console test can see.
  if [[ $PROFILE_ROLE == live ]]; then
    [[ -e $T/usr/share/i18n/SUPPORTED ]] \
      && violation "/usr/share/i18n/SUPPORTED survived the prune on a live medium. Calamares'
  locale module reads it BEFORE localeGenPath, so its language dialog will offer the ~500 locales
  glibc could build instead of the nine this image compiled — and choosing any of the others gives
  the installed system LANG=en_US.UTF-8 and a warning nobody reads (plan/22 §6)"
    # The other half, and it has to be the other half: the fallback is only reached if the file
    # above is gone, and it is only USEFUL if what it falls back to exists.
    [[ -s $T/etc/locale.gen ]] \
      || violation "/etc/locale.gen is missing or empty on a live medium. With
  /usr/share/i18n/SUPPORTED deleted it is the installer's ONLY source of available locales, so the
  locale page would come up with an empty list and a warning in the log"
    while IFS='|' read -r li _ _ _; do
      [[ -n $li && $li != en ]] || continue
      [[ -s $T/etc/calamares/branding/installer/lang/calamares-installer_${li}.qm ]] \
        || violation "the compiled translation for '$li' is missing from the branding component.
  Stage 40 built it from config/calamares/branding/installer/lang/; without it every page this
  project wrote is English for a user who picked that language (plan/22 §4)"
    done <<<"$LANGUAGES_TABLE"
  fi

  if [[ $PROFILE_ROLE == live ]]; then
    [[ -d $T/usr/share/wallpapers/$DISTRO_ID ]] \
      || violation "/usr/share/wallpapers/$DISTRO_ID is missing from a live medium. Stage 40
  installs it from config/calamares/system/wallpaper and the layout script and the lock screen
  both name it by path, so this medium has a wallpaper plugin pointed at nothing"
    wp_extra="$(find "$T/usr/share/wallpapers" -mindepth 1 -maxdepth 1 ! -name "$DISTRO_ID" \
                     2>/dev/null || true)"
    [[ -n $wp_extra ]] \
      && violation "wallpapers other than $DISTRO_ID survived the prune on a live medium —
  section 3i did not run, or ran before something reinstalled them, and this is up to 255 MiB
  of PNG that EROFS gives back 1% of: $wp_extra"
    # Breeze's own default, named separately from the sweep above because it is the 38.3 MiB half
    # that has no set marker and no USE flag behind it — if 3i ever stops matching, this is the
    # one that comes back.
    [[ -e $T/usr/share/wallpapers/Next ]] \
      && violation "Breeze's Next wallpaper is back on a live medium — 38.3 MiB that section
  3i is supposed to delete, because kde-plasma/breeze cannot be dropped as a package"
    WP_LAYOUT="$T/usr/share/plasma/look-and-feel/$DISTRO_ID/contents/layouts/org.kde.plasma.desktop-layout.js"
    if [[ -f $WP_LAYOUT ]]; then
      grep -qF "wallpaperPlugin = 'org.kde.image'" "$WP_LAYOUT" \
        || violation "the live medium's layout script does not select org.kde.image.
  ShellCorona::loadDefaultLayout() runs it once, on the first session, and it is the only thing
  that decides what the containment draws"
      grep -qF "'/usr/share/wallpapers/$DISTRO_ID/'" "$WP_LAYOUT" \
        || violation "the live medium's layout script selects org.kde.image but does not name
  /usr/share/wallpapers/$DISTRO_ID. The unnamed fallback is Breeze's Next, which section 3i
  has just deleted, so the containment would come up blank"
    else
      violation "no layout script in the live medium's look-and-feel package
  ($DISTRO_ID/contents/layouts) — stage 40 installs it for live profiles and it is what points
  the containment at the one wallpaper section 3i left in place"
    fi
    # The lock screen is a different file reading a different config group, and on this medium it
    # is the screen most likely to be facing the room: Autolock stays on, so the shield engages
    # five minutes into an unattended install.
    LOCKRC="$T/etc/xdg/kscreenlockerrc"
    if [[ -f $LOCKRC ]]; then
      grep -qF "Image=/usr/share/wallpapers/$DISTRO_ID/" "$LOCKRC" \
        || violation "/etc/xdg/kscreenlockerrc does not point the greeter at
  /usr/share/wallpapers/$DISTRO_ID. kscreenlocker does not read the containment's wallpaper —
  its own fallback chain ends at Breeze's Next, which section 3i deleted, so the lock screen
  would draw black behind the unlock UI"
    else
      violation "no /etc/xdg/kscreenlockerrc on a live medium — stage 40 installs it from
  config/calamares/system/kscreenlockerrc.in, and it carries both the password-prompt answer and
  the greeter's wallpaper"
    fi
    # Section 3k, asserted the way 3g and 3h are: one name, both descriptors, and the binary.
    emoji_left="$(find "$T/usr/share/applications" "$T/usr/share/kglobalaccel" "$T/usr/bin" \
                       "$T/usr/lib64/qt6/qml/org/kde/plasma" -maxdepth 1 \
                       \( -name '*emojier*' -o -name 'emoji' \) 2>/dev/null || true)"
    [[ -n $emoji_left ]] \
      && violation "the Emoji Selector survived the prune on a live medium — section 3k's paths
  no longer match what kde-plasma/plasma-desktop installs: $emoji_left"
  else
    # ...and the other direction, which is the one that would damage the PRODUCT. If 3i's role
    # check ever widened, the desktop image would ship with no background and nothing here would
    # be different — the containment still asks org.kde.image for `Next`, and gets nothing.
    [[ -d $T/usr/share/wallpapers/Next ]] \
      || violation "/usr/share/wallpapers/Next is missing from a PROFILE_ROLE=$PROFILE_ROLE
  image. It is kde-plasma/breeze's default wallpaper and org.kde.breeze.desktop/contents/defaults
  names it ([Wallpaper] Image=Next), so the desktop would come up with no background. Section 3i
  is supposed to run on live media only"
  fi
fi
# ---- the installer medium (plan/16) ------------------------------------------------------
# Live-only, and nothing here is reachable by stage 70 either: it reads a serial port, so an
# installer image whose GUI cannot install still reports green.
if profile_has_set installer; then
  [[ -x $T/usr/bin/calamares ]] \
    || violation "calamares missing after prune — the installer medium has no installer"
  # Stage 40's finalizer builds this; cracklib's pkg_postinst never does, because it is guarded
  # on `[[ -z ${ROOT} ]]` and stage 30 merges with ROOT=$TARGET. It lands as three plain files
  # at /usr/lib maxdepth 1 — the exact directory and depth section 3d sweeps. 3d deletes by FILE
  # CONTENT (ELFCLASS32 or a GNU ld script), so they are safe today; rewriting that sweep to
  # anything name- or depth-based would take the dictionary with it, and the only symptom would
  # be an installer that rejects every password on its users page.
  for cl_ext in pwd pwi hwm; do
    [[ -s $T/usr/lib/cracklib_dict.$cl_ext ]] \
      || violation "/usr/lib/cracklib_dict.$cl_ext missing after prune — libpwquality would reject
  every password on Calamares' users page with 'The password fails the dictionary check -
  error loading dictionary', and the install could never get past it"
  done
  # Section 3j: GRUB must be gone, and its removal must not have taken the installer with it.
  # A deletion by path is a silent no-op the moment a path stops matching — sys-boot/grub is
  # still an unconditional RDEPEND of calamares, so the package will keep arriving and only this
  # check would notice that 68 MiB of it came back.
  for g in usr/lib/grub usr/share/grub usr/bin/grub-install usr/bin/grub-mkconfig etc/grub.d \
           etc/default/grub; do
    [[ -e $T/$g ]] \
      && violation "GRUB residue after prune: /$g — section 3j's paths no longer match what
  sys-boot/grub installs, and this medium is carrying a bootloader it never runs"
  done
  # ...and the deletion must not have widened into what the install actually writes. The
  # bootloader the INSTALLED machine gets is systemd-boot, read by the imagebootloader module
  # out of the mounted target's own /usr — not from this medium — but this is the assertion
  # that says 3j cut the dead bootloader and not the live one.
  [[ -f $T/usr/lib/systemd/boot/efi/systemd-bootx64.efi ]] \
    || violation "systemd-bootx64.efi is missing from the live medium after prune. Section 3j
  removed GRUB; systemd-boot is the bootloader this distro actually uses, and its absence here
  means the prune cut the wrong one"
fi
# ---- the container stack (plan/13) ------------------------------------------------------
# Every one of these fails the same invisible way: stage 70 reads a serial port and an image
# whose rootless stack is broken still reports green, so the failure would first appear when a
# user types `distrobox create` on real hardware.
if [[ ${INCLUDE_DISTROBOX:-1} == 1 ]]; then
  for b in podman distrobox distrobox-enter distrobox-create crun conmon pasta docker; do
    [[ -x $T/usr/bin/$b || -x $T/usr/sbin/$b ]] \
      || violation "$b missing after prune — the container stack is incomplete"
  done
  # THE assertion of this block. newuidmap/newgidmap are setuid-root helpers (mode 4755, NOT
  # file capabilities — which is why EROFS carries them at all), and they are the only way an
  # unprivileged process can claim its subuid range. A prune, a chmod sweep or a filesystem
  # that dropped the setuid bit leaves the binaries present and rootless podman dead, with an
  # error that names neither.
  for b in newuidmap newgidmap; do
    p="$T/usr/bin/$b"
    [[ -e $p ]] || { violation "$b missing — rootless podman cannot map its subuid range"; continue; }
    [[ $(stat -c '%a' "$p" 2>/dev/null) == 4755 ]] \
      && continue
    violation "$b is mode $(stat -c '%a' "$p" 2>/dev/null), expected 4755 — without the setuid bit
  rootless podman fails with 'newuidmap: write to uid_map failed'"
  done
  # The ranges themselves. Stage 40 allocates them explicitly when useradd did not; this is the
  # check that the allocation actually landed in the image rather than in a chroot's /run.
  for f in subuid subgid; do
    grep -q "^${LIVE_USER}:" "$T/etc/$f" 2>/dev/null \
      || violation "/etc/$f has no range for $LIVE_USER — rootless podman would fail for the live user"
  done
  # Rootless means rootless: no system-wide podman API socket may be enabled. Stage 40's preset
  # disables it, but preset-all also applies VENDOR presets, which is exactly how systemd-networkd
  # got enabled behind our backs once already (plan/03).
  find "$T/etc/systemd/system" -name 'podman.socket' 2>/dev/null | grep -q . \
    && violation "podman.socket is enabled — this image runs containers rootless only"
  [[ -e $T/usr/lib/tmpfiles.d/podman-docker.conf ]] \
    && violation "podman-docker.conf survived section 3 — it symlinks /run/docker.sock at a rootful
  socket this image never starts"
else
  # The switch has to be structural, not cosmetic: an INCLUDE_DISTROBOX=0 image that still
  # carries podman means filter_set_file silently stopped filtering.
  [[ -e $T/usr/bin/podman || -e $T/usr/bin/distrobox ]] \
    && violation "INCLUDE_DISTROBOX=0 but the container stack is in the image — the #distrobox
  set marker did not filter"
  [[ -e $T/etc/distrobox ]] \
    && violation "INCLUDE_DISTROBOX=0 but /etc/distrobox shipped"
fi
# ...but deleting /usr/src must not have taken the prebuilt out-of-tree modules with it: they
# live in /usr/lib/modules/<kver>/, and a machine that boots without them has no NVIDIA driver
# at all — a failure that would otherwise only surface on real hardware, never in stage 70's
# virtio VM.
find "$T/usr/lib/modules" -name 'nvidia*.ko*' 2>/dev/null | grep -q . \
  || violation "no nvidia*.ko in /usr/lib/modules — the /usr/src prune cut too deep"
# ...and section 3f must not have taken them either. The dead-module sweep matches on names, and
# "nouveau" and "nvidia" are one careless glob apart — a `-name 'n*.ko'` slip would remove the
# only GPU driver this image has and show up nowhere until a machine boots to a black screen.
if find "$T/usr/lib/modules" -name 'nouveau.ko*' 2>/dev/null | grep -q .; then
  violation "nouveau.ko survived section 3f — it is blacklisted by nvidia.conf and its firmware is
  already pruned, so it can only ever be dead weight"
fi
# CPU microcode must be gone from the root filesystem: the UKI's early cpio is the only reader
# (see the note in section 3). Stage 40 asserts the other half — that the UKI actually has it.
for d in intel-ucode amd-ucode; do
  [[ -e $T/usr/lib/firmware/$d ]] \
    && violation "/usr/lib/firmware/$d survived the prune — it is dead weight on a read-only root
  and the UKI already carries the copy the kernel loads"
done
# The module indexes must describe what actually ships. A stale modules.dep does not fail at
# build time and does not fail at boot; it fails the first time something modprobes a module whose
# recorded dependency was deleted, and it reports the error against the wrong module.
if [[ -n ${KVER:-} && -f $T/usr/lib/modules/$KVER/modules.dep ]]; then
  dep_missing="$(comm -23 \
    <(sed 's/:/ /' "$T/usr/lib/modules/$KVER/modules.dep" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u) \
    <(cd "$T/usr/lib/modules/$KVER" && find . -name '*.ko*' -printf '%P\n' | LC_ALL=C sort -u) \
    | head -5)"
  [[ -n $dep_missing ]] \
    && violation "modules.dep names files that are not in the image (did depmod run after the
  prune?): $(tr '\n' ' ' <<<"$dep_missing")"
fi
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

# ---- the Active Directory client (plan/18) ------------------------------------------------
# Every profile ships @domain, so every profile is checked. Each of these is invisible to stage
# 70 — it reads a serial port on a machine that is not joined to anything — and unfixable on the
# target, which has no package manager. So the prune is where they have to be caught.
#
# The NSS module first, for the same reason libnss_resolve is checked above: /etc/nsswitch.conf
# names sss, glibc dlopen()s it, and a missing one is not an error anywhere — just a domain user
# who does not exist.
compgen -G "$T/usr/lib64/libnss_sss.so"* >/dev/null \
  || compgen -G "$T/usr/lib/libnss_sss.so"* >/dev/null \
  || violation "libnss_sss missing after prune (/etc/nsswitch.conf names the sss module)"
# The PAM modules. pam_sss is what authenticates a domain user; pam_mkhomedir is what gives them
# somewhere to log in TO, and stage 40 put it in the system-login session stack by hand.
for pm in pam_sss pam_mkhomedir; do
  [[ -e $T/lib64/security/$pm.so || -e $T/usr/lib64/security/$pm.so ]] \
    || violation "$pm.so missing after prune — /etc/pam.d names it, and PAM treats a missing
  module in a non-optional line as a failure of the whole stack"
done
# The daemon, the join tool, and the CLI that drives both.
[[ -x $T/usr/sbin/sssd  || -x $T/usr/bin/sssd  ]] || violation "sssd missing after prune"
# THE PROVIDER MODULE, which is a separate check from the daemon and is the one this file
# learned the hard way. sssd's back end is a dlopen() plugin per id_provider; the daemon, the NSS
# module, the PAM module, adcli and `sssctl config-check` are all perfectly happy without it. An
# image built with sys-auth/sssd[-samba] passed every assertion above, validated its generated
# sssd.conf clean, and JOINED THE DOMAIN — adcli wrote the keytab and the computer account was
# created — and only then did sssd refuse to start:
#
#   dp_module_open_lib: Unable to load module [ad] with path [/usr/lib64/sssd/libsss_ad.so]:
#   cannot open shared object file: No such file or directory
#
# So the check is not "is sssd installed" but "can sssd load the provider its own config names".
# Derived from the CLI rather than hardcoded, so that changing id_provider without shipping the
# module fails here instead of on a user's machine.
# --computer-name is pinned rather than derived: with no --root the CLI would read the BUILDER's
# hostname, and this container's is long enough to trip the 15-character sAMAccountName check.
# Rendered once into a variable rather than piped into `head`: head exits at the first line,
# the CLI dies of SIGPIPE, and `set -o pipefail` then reports the whole pipeline as failed.
SSSD_SAMPLE="$(bash "$T/usr/bin/${DISTRO_ID}-domain" join --domain prune.invalid \
  --user check --computer-name PRUNECHECK --print-config sssd 2>/dev/null || true)"
SSSD_PROVIDER="$(sed -n 's/^[[:space:]]*id_provider[[:space:]]*=[[:space:]]*\([a-z0-9_]\{1,\}\).*/\1/p' \
  <<<"$SSSD_SAMPLE" | tail -1)"
[[ -n $SSSD_PROVIDER ]] \
  || violation "could not read id_provider out of ${DISTRO_ID}-domain --print-config sssd"
[[ -e $T/usr/lib64/sssd/libsss_$SSSD_PROVIDER.so || -e $T/usr/lib/sssd/libsss_$SSSD_PROVIDER.so ]] \
  || violation "libsss_$SSSD_PROVIDER.so is missing — sssd.conf says id_provider = $SSSD_PROVIDER
  and the back end dlopen()s that module by name. Everything else about the join succeeds and
  sssd then fails to start. The AD provider is built ONLY under sys-auth/sssd[samba]; check that
  flag in config/portage/package.use/image before looking at the prune list"
[[ -x $T/usr/sbin/adcli || -x $T/usr/bin/adcli ]] || violation "adcli missing after prune — no
  machine could be joined to a domain, and there is no way to install it later"
[[ -x $T/usr/bin/${DISTRO_ID}-domain ]] \
  || violation "/usr/bin/${DISTRO_ID}-domain missing after prune"
# nsupdate is the ONLY reason net-dns/bind is in the image (sssd's DEPEND carries it with no USE
# guard; plan/18 §6.3). If a future trim of that package removes it, sssd's dyndns_update stops
# registering the machine in AD DNS — silently, because sssd logs the failure and carries on.
[[ -x $T/usr/bin/nsupdate ]] \
  || violation "nsupdate missing after prune — sssd's dyndns_update would silently stop
  registering this machine's A record in Active Directory DNS"
# kinit is how `${DISTRO_ID}-domain verify` proves an account will actually authenticate, which
# is the check standing between an unreachable domain controller and a Calamares install that
# stops after the disk is written (plan/18 §7.4). The CLI degrades to a reachability-only check
# without it rather than failing, so its absence would cost nothing visible at build time and
# the entire credential half of the preflight at install time.
[[ -x $T/usr/bin/kinit ]] \
  || violation "kinit missing after prune — ${DISTRO_ID}-domain verify would silently drop its
  credential check and the installer would discover a bad password by failing the join"
# The Kerberos profile pair. A missing includedir is not a warning to MIT Kerberos: it is
# "Included profile directory could not be read", and every kinit on the machine fails.
[[ -f $T/etc/krb5.conf ]] || violation "/etc/krb5.conf missing after prune"
[[ -d $T/etc/krb5.conf.d ]] \
  || violation "/etc/krb5.conf.d missing after prune — /etc/krb5.conf includes it, and MIT
  Kerberos fails to read ANY profile when an includedir does not exist"
# ...and sssd must still be disabled. A prune that resurrected an enablement symlink would turn
# every unjoined boot into a failed one (plan/18 §5.1).
# The glob covers winbind* as well as sssd*: net-fs/samba[winbind] rides in with sssd[samba],
# and winbindd started on an unjoined machine fails exactly the same way — under a name this
# check used to not look for.
SSSD_ENABLED_AFTER="$(find "$T/etc/systemd/system" \( -name 'sssd*' -o -name 'winbind*' \) \
  -printf '%P\n' 2>/dev/null | tr '\n' ' ')"
if [[ -n ${SSSD_ENABLED_AFTER// /} ]]; then
  violation "domain units enabled after prune: $SSSD_ENABLED_AFTER — an unjoined machine would
  fail boot-complete.target and roll back to the previous image"
fi
# ---- managed mode, after the prune (plan/19 §12) --------------------------------------------
# Checked here as well as in stage 40 for the reason the splash is: this stage is where it would
# plausibly be LOST. Managed mode costs no packages, so nothing in the lock file or the audit
# list mentions it — every part of it is either a file this repo ships into /usr or a symbol
# inside sys-apps/systemd, and both are things a /usr/share sweep or a systemd trim can take.
[[ -x $T/usr/bin/$DISTRO_ID-managed ]] \
  || violation "/usr/bin/$DISTRO_ID-managed missing after prune — the image can no longer be
  enrolled, and there is no Portage on the target to put it back"
[[ -s $T/usr/lib/$DISTRO_ID/managed-pubring.gpg ]] \
  || violation "/usr/lib/$DISTRO_ID/managed-pubring.gpg missing after prune — no policy bundle
  could be verified, so managed mode would refuse every sync on a machine that had enrolled"
# The identity mechanism itself: one symbol in one shared object (plan/19 §2.2). A prune that
# took libnss_systemd.so leaves an image where managed users resolve nowhere and local login is
# unaffected — so nothing else here would notice.
MANAGED_NSS="$(compgen -G "$T/usr/lib64/libnss_systemd.so"* || compgen -G "$T/lib64/libnss_systemd.so"* || true)"
if [[ -z $MANAGED_NSS ]]; then
  violation "libnss_systemd.so missing after prune — /etc/nsswitch.conf names the systemd module
  on passwd, group AND shadow, and managed mode's whole authentication path is its shadow half"
else
  MANAGED_SYMS="$(nm -D --defined-only "${MANAGED_NSS%% *}" 2>/dev/null \
                  || readelf -sW --dyn-syms "${MANAGED_NSS%% *}" 2>/dev/null || true)"
  [[ $MANAGED_SYMS == *_nss_systemd_getspnam_r* ]] \
    || violation "libnss_systemd.so no longer exports _nss_systemd_getspnam_r — a managed user
  would resolve through getent passwd and have no password to check"
fi
# The front end, in whichever direction this profile wants it. On a medium somebody keeps, the
# /usr/share sweeps above run straight over this path and taking it leaves a wrapper that opens
# on nothing. On a live medium stage 40 removed all three files on purpose (plan/20 §2.2), and
# the check that matters is the opposite one — the front end ships from config/rootfs, not from
# a package, so neither the lock nor the audit would ever mention it coming back.
if [[ $PROFILE_ROLE == live ]]; then
  MANAGED_UI_AFTER=""
  for f in "usr/bin/$DISTRO_ID-managed-ui" \
           "usr/share/applications/$DISTRO_ID-managed-ui.desktop" \
           "usr/share/$DISTRO_ID/managed-ui"; do
    [[ -e $T/$f ]] && MANAGED_UI_AFTER+=" /$f"
  done
  [[ -z ${MANAGED_UI_AFTER// /} ]] \
    || violation "the managed-mode front end survived onto a PROFILE_ROLE=$PROFILE_ROLE medium:$MANAGED_UI_AFTER
  A live session is never enrolled, so this is a 'Managed Settings' entry in Kickoff that can
  only answer 'not enrolled'. Stage 40 removes it just after install_rootfs_overlay; if it is
  here, those paths no longer match what the overlay installs."
else
  [[ -f $T/usr/share/$DISTRO_ID/managed-ui/main.qml ]] \
    || violation "/usr/share/$DISTRO_ID/managed-ui/main.qml missing after prune — the /usr/share
  sweeps run over this path, and without it the front end opens on nothing"
fi
# ...and the timer must still be disabled, for exactly the reason sssd must be (plan/19 §8.1).
MANAGED_ENABLED_AFTER="$(find "$T/etc/systemd/system" -name "$DISTRO_ID-managed*" \
  -printf '%P\n' 2>/dev/null | tr '\n' ' ')"
if [[ -n ${MANAGED_ENABLED_AFTER// /} ]]; then
  violation "managed-mode units enabled after prune: $MANAGED_ENABLED_AFTER — an unenrolled
  machine would run a sync it has nothing to sync, and a non-zero exit is a failed boot"
fi
[[ -e $T/etc/userdb ]] \
  && violation "/etc/userdb exists after prune. It is created by enrolment; an image that ships
  it puts a directory in the read-only lower that the /etc overlay then has to shadow (T-MAN-5)"
# Phase D's compiled surfaces, IF this build installed them (plan/19 §7.2). Neither is asserted
# into existence — a build whose lock predates the overlay must stay green — so what is checked
# is that the halves still MATCH each other. A prune that took one and left the other is silent
# in both directions, and each direction fails differently.
MANAGED_KCM_SO="$(compgen -G "$T/usr/lib*/qt6/plugins/plasma/kcms/systemsettings/kcm_managed.so" || true)"
MANAGED_KCM_DESKTOP="$(compgen -G "$T/usr/share/applications/kcm_managed.desktop" || true)"
# ...except on a live medium, where the answer is that neither half should be here at all
# (plan/20). The KCM is `#not-live` in config/portage/sets/desktop, so a live build never
# emerges it — and if one turns up anyway, filter_set_file is not filtering or the profile's
# lock was resolved before the marker existed. Neither is visible any other way: the module
# would simply appear in a System Settings nobody opens, on a stick that enrols nothing.
if [[ $PROFILE_ROLE == live && ( -n $MANAGED_KCM_SO || -n $MANAGED_KCM_DESKTOP ) ]]; then
  violation "the managed-mode System Settings module is installed on a PROFILE_ROLE=$PROFILE_ROLE
  medium. It is marked #not-live in config/portage/sets/desktop because a live session is never
  enrolled; re-resolve this profile's lock:
      scripts/relock.sh --all --profile $BUILD_PROFILE"
fi
if [[ -n $MANAGED_KCM_DESKTOP && -z $MANAGED_KCM_SO ]]; then
  violation "kcm_managed.desktop survived the prune but kcm_managed.so did not — System Settings
  would list a module whose plugin is gone, and opening it is an error dialog"
fi
if [[ -n $MANAGED_KCM_SO && -z $MANAGED_KCM_DESKTOP ]]; then
  violation "kcm_managed.so survived the prune but its .desktop did not — the module is still in
  System Settings and no longer comes up when anyone searches for it"
fi
# The Calamares module is installer-only, and there its whole directory has to survive: the .so
# and the module.desc beside it are read as a pair by ModuleManager.
MANAGED_CAL="$(compgen -G "$T/usr/lib*/calamares/modules/managed" || true)"
if [[ -n $MANAGED_CAL ]]; then
  compgen -G "$T/usr/lib*/calamares/modules/managed/module.desc" >/dev/null \
    || violation "the managed Calamares module directory survived the prune without its
  module.desc — ModuleManager reads the descriptor to find the plugin, so the enrolment page
  would be dropped from the sequence with no error anywhere"
fi

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
# The boot splash, in full. None of this is reachable by any automated test we have — stage 70
# reads a serial port, so an image whose splash was pruned to nothing boots to a black screen
# and still reports green.
#
# It is asserted HERE, after the prune, as well as in stage 40, because this stage is where it
# would plausibly be lost: section 3b's toolchain split and the /usr/share sweeps both run over
# the two paths below. The binary is static precisely so that no library prune can break it —
# but nothing stops a prune deleting the binary or its assets outright.
[[ -x $T/usr/bin/$DISTRO_ID-splash ]] \
  || violation "/usr/bin/$DISTRO_ID-splash missing after prune — the image would boot to a black screen"
[[ -s $T/usr/share/$DISTRO_ID/splash.bin ]] \
  || violation "/usr/share/$DISTRO_ID/splash.bin missing after prune — the splash binary would find no assets and exit silently"
# Console-only images have neither (stage 40 removes them: agetty owns the framebuffer there).
if [[ -f $T/usr/lib/systemd/system/$DISTRO_ID-splash.service ]]; then
  [[ -f $T/usr/lib/udev/rules.d/70-$DISTRO_ID-splash.rules ]] \
    || violation "the splash unit survived the prune but its udev rule did not — nothing would start it"
fi

# NetworkManager itself is the whole point of removing networkd; assert it outlived it.
compgen -G "$T/usr/sbin/NetworkManager" >/dev/null \
  || compgen -G "$T/usr/bin/NetworkManager" >/dev/null \
  || compgen -G "$T/usr/libexec/NetworkManager" >/dev/null \
  || violation "NetworkManager binary missing after prune — the image has no network manager at all"
# Both *.la and *.a scans exclude /var/lib/flatpak: the toolchain-free guarantee (plan/06) is
# about what THIS pipeline's own emerge puts in the target — its three layers (BDEPEND/RDEPEND
# split, INSTALL_MASK, this sweep) are all portage-scoped by construction. Flatpak app payloads
# arrive from Flathub as opaque third-party binaries, outside all three layers already, and
# outside this pipeline's control — pruning inside one risks breaking an app whose own build
# had a reason (however sloppy) to ship the file. Found when org.kde.okular's VLC-based backend
# turned out to bundle lib/vlc/libcompat.a inside its own sandboxed files/ tree.
find "$T" -xdev -path "$T/var/lib/flatpak" -prune -o -name '*.la' -print 2>/dev/null \
  | grep -q . && violation "*.la files remain"
# Same rule as *.la, and it belongs here for the same reason: a static archive is a link-time
# input, so one surviving anywhere means a sweep grew a blind spot. This one is image-wide, not
# scoped to the two libdirs the deletion covers — if a package ever installs a .a somewhere else,
# this is where that should be noticed.
a_left="$(find "$T" -xdev -path "$T/var/lib/flatpak" -prune -o -name '*.a' -print 2>/dev/null | head -5)"
[[ -n $a_left ]] && violation "static archives remain: $a_left"
# 32-bit multilib residue (section 3d). Named-pattern check rather than an ELF-class re-scan:
# after 3d there should be no shared object or relocatable at all at /usr/lib maxdepth 1.
m32="$(find "$T/usr/lib" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.o' \) 2>/dev/null | head -5)"
[[ -n $m32 ]] && violation "32-bit multilib residue in /usr/lib: $m32"
[[ -e $T/usr/lib/cpp ]] && violation "/usr/lib/cpp (compiler driver symlink) survived the prune"
# ...and the one link at that depth that must NOT be swept. 3e deletes every dangling symlink in
# /usr/lib maxdepth 1, and /usr/lib/terminfo -> ../share/terminfo lives there: it resolves today
# only because section 3's /usr/share deletions do not include terminfo. Reorder those and this
# sweep silently takes the terminal database with it — plan/06 lists terminfo under "deliberately
# KEPT", and the failure would surface as an unusable console during recovery, which is exactly
# when nobody can debug it. Caught by a mutation test of 3e, not by a build.
[[ -d $T/usr/lib/terminfo || -d $T/usr/share/terminfo ]] \
  || violation "terminfo is gone — the dangling-link sweep in 3e cut too deep"
# ...and the console that terminfo exists for must actually be reachable. Gentoo builds systemd
# with -Dsplit-bin=false, so every getty unit it ships says ExecStart=-/usr/bin/agetty; a root
# whose /usr/sbin is a real directory rather than a symlink to bin leaves agetty somewhere no
# unit looks. The "-" prefix then swallows the 203/EXEC, the unit respawns forever, and
# `systemctl --failed` stays clean — so this ships as "no way to log in at a console" with every
# other check green. That was true of every image before 0.3.0 (see seed_merged_usr).
# Asserted as a resolvable PATH-style lookup, not as a file test on one location, because that
# is the question the units actually ask.
[[ -L $T/usr/sbin ]] \
  || violation "/usr/sbin is not a symlink to bin — the merged-usr seed regressed to sbin-split,
  which strands ~259 binaries where no systemd unit will look for them (agetty, and with it
  every getty, is the one that bites)"
[[ -x $T/usr/bin/agetty ]] \
  || violation "no /usr/bin/agetty — getty@, serial-getty@, console-getty and container-getty@
  all name that exact path and all fail 203/EXEC silently, leaving the image with no text
  console login on tty1 or serial"
# ...and the counterpart: 3d deletes by ELF class inside a directory that also holds live files,
# so assert the most load-bearing of them is still there. systemd reads /usr/lib/os-release on
# every boot and /etc/os-release is a symlink to it.
[[ -s $T/usr/lib/os-release ]] \
  || violation "/usr/lib/os-release missing or empty — the multilib sweep in 3d cut too deep"
# no dangling symlinks in the module tree: section 3e removes the three that pointed into the
# deleted /usr/src, and a kernel bump adding a fourth should fail loudly rather than ship a
# broken vmlinuz link that dracut and kernel-install both follow.
# NB: resolved the same way 3e resolves them, NOT with `find -exec test -e`. test(1) would
# resolve an ABSOLUTE link against the BUILDER's root, which is a different filesystem — that
# reports a link as present when the image lacks it, and as broken when the builder lacks it.
while IFS= read -r -d '' l; do
  lt="$(readlink -- "$l")"
  if [[ $lt == /* ]]; then [[ -e "$T$lt" ]] && continue
  else [[ -e "$(dirname -- "$l")/$lt" ]] && continue; fi
  violation "dangling symlink under /usr/lib/modules: ${l#"$T"} -> $lt"
done < <(find "$T/usr/lib/modules" -type l -print0 2>/dev/null)

# Interpreter policy (plan/06). The rule is that an interpreter in the image is a call a human
# made and recorded — here, in plan/06 and in expected-packages.txt — never something tolerated
# silently.
#
#   allowed: dev-lang/perl + dev-perl/Parse-Yapp. net-fs/samba lists both in COMMON_DEPEND with
#            no USE guard, and samba is a hard dep of kde-apps/kio-extras[samba], kept
#            deliberately for smb:// browsing in Dolphin. The escape hatch is one flag —
#            kio-extras[-samba] drops samba, perl and Parse-Yapp together, at the cost of
#            smb://. x11-misc/xdg-utils[-perl,-gnome] keeps the other ~48 perl packages out.
#            (Holder changed with the desktop; the dependency fact did not. It used to arrive
#            behind gnome-control-center[cups] -> app-admin/system-config-printer -> samba.)
#
#   python:  UNDECIDED, deliberately. It was admitted under GNOME because gnome-base/gnome-shell
#            folds DEPEND — dev-python/{docutils,pygobject} — into RDEPEND, and that chain no
#            longer exists. Do NOT pre-emptively ban it: let the first Plasma build's
#            expected-packages.txt.generated say what actually arrives and why, then record the
#            surviving allowlist WITH ITS CHAIN, the way the perl entry above does.
#
#   still banned: pip and every compiler/build tool swept for above.
#
# The toolchain-free guarantee itself is unchanged: no compiler, no Portage, no headers.

# same shape as the gcc split below: mesa's radeonsi and llvmpipe drivers dlopen libLLVM.so, so
# the one thing section 3a must never remove is the library it kept the directory for.
compgen -G "$T/usr/lib/llvm/"*/lib64/libLLVM.so* >/dev/null \
  || compgen -G "$T/usr/lib64/libLLVM.so"* >/dev/null \
  || violation "libLLVM.so missing after prune — mesa's radeonsi/llvmpipe will not load"

# the toolchain split must leave the runtime behind: a desktop with no libstdc++ boots to
# nothing, and that failure would otherwise only show up in QEMU (stage 70) or on hardware.
# libgomp joined this list when 3b started deleting its neighbours: it has only 3 DT_NEEDED
# references in the image (against libstdc++'s 1159), which is exactly the profile that makes a
# library look droppable to the next person editing that loop. It is not — ghostscript and
# libqalculate link it.
#
# That count is now PROFILE-DEPENDENT and gets smaller, not larger: the installer medium drops
# ghostscript (package.use/profile.installer) and OpenCV (Spectacle is #not-live), so on a live
# build libqalculate may be the only consumer left (plan/20 §2.4, §2.5). The assertion is
# unaffected — it checks that gcc's runtime file is PRESENT, and sys-devel/gcc installs it into
# every root regardless of who links it — but do not read the sentence above as a live count.
for lib in libstdc++.so.6 libgcc_s.so.1 libgomp.so.1; do
  find "$T/usr/lib/gcc" -name "$lib" 2>/dev/null | grep -q . \
    || violation "gcc runtime library $lib missing after prune (toolchain split cut too deep)"
done

[[ $fail == 0 ]] || die "prune assertions failed — see PRUNE VIOLATION lines above"

du -xsm "$T" | tail -n1 | tee -a "$REPORT_DIR/size-report.txt"
log "prune complete, all assertions passed"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" \
  "$REPO/config/prune-firmware.txt" "$REPO/config/prune-microcode.txt")"
