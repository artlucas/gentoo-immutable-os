# Builder container: full Gentoo with toolchain + image-assembly tools.
# The target rootfs is emerged from inside this container with --root= (plan/02).
#
# Pin via: docker build --build-arg BASE="gentoo/stage3:amd64-systemd@sha256:<digest>"
# (BUILDER_DIGEST in config/build.conf; build.sh passes it through).
ARG BASE=gentoo/stage3:amd64-systemd
FROM ${BASE}

# Snapshot the ebuild repo inside the image so the builder itself is cacheable.
# Stage 10 re-verifies/moves the tree to the SNAPSHOT_DATE pin at run time.
RUN emerge-webrsync

# Binary packages for the BUILDER's own "/". This is the builder only — the target's binhost
# is configured separately in config/portage/make.conf.in and is not affected by anything here.
#
# The stage3 base already ships /etc/portage/binrepos.conf/gentoo.conf pointing at the official
# binhost with verify-signature = true, and already has sec-keys/openpgp-keys-gentoo-release
# installed. The one thing it does not have is FEATURES=getbinpkg — so every package in the
# emerge below was compiled from source, ~98 of them, about an hour of wall clock on any change
# to this file. The tools here (qemu, dracut, systemd, librsvg, shellcheck) are stock packages
# with no image-specific requirements; there is no reason to build them.
#
# getuto MUST run BEFORE that emerge, not after. verify-signature = true makes portage check
# binpkg signatures against the trust store in /etc/portage/gnupg, and getuto is what creates
# that store from the installed release keys. Without it portage cannot verify anything the
# binhost serves and quietly falls back to building from source — the failure mode is a slow
# build, not an error, which is exactly how this would regress unnoticed.
#
# The URI comes from BINHOST_URI in config/build.conf (build.sh passes it as a build-arg), so
# the builder and the target resolve the same binhost and a local mirror only has to be set in
# one place. Packages whose USE this image overrides below (mesa[vulkan], polkit[gtk], the
# qemu target list, ...) still build from source: the binhost's copies were built against the
# default profile's USE and portage correctly refuses a mismatched binpkg.
ARG BINHOST=https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/
RUN printf 'FEATURES="${FEATURES} getbinpkg"\n' >> /etc/portage/make.conf \
 && printf '[gentoo]\npriority = 1\nsync-uri = %s\nlocation = /var/cache/binhost/gentoo\nverify-signature = true\n' \
      "$BINHOST" > /etc/portage/binrepos.conf/gentoo.conf \
 && GETUTO_EXTERNAL_REFRESH=0 getuto

# Host-side tools (never enter the target):
#  - erofs/vfat/ext4 + mtools: loopless image assembly (stage 60)
#  - dracut: initrd for the UKI (stage 40)
#  - qemu + OVMF: boot tests (stage 70)
#  - librsvg (rsvg-convert) + media-fonts/ibm-plex: rasterise the boot-splash SVGs in
#    config/branding into the plymouth theme (stage 40). Both are BUILD tools and never enter
#    the image — that is the whole point: the splash ships as PNGs so no font has to. They live
#    here rather than in config/portage/sets/buildhost because that set is emerged in stage 30,
#    and every stage runs in its own --rm container, so a stage-30 install is gone by stage 40.
#  - dev-python/pillow: composes the systemd-stub .splash bitmap from those same PNGs when
#    SPLASH_BACKEND includes the stub (stage 40, config/branding/make-stub-bmp.py). rsvg-convert
#    cannot emit BMP — its formats are png/pdf/ps/svg — and BMP is the only container the EFI
#    stub reads. Named explicitly because it was already present here transitively, and a
#    dependency that arrives by accident is one a graph change can remove by accident.
#  - gnupg + sec-keys/openpgp-keys-gentoo-release + getuto: trust store for binhost
#    signature verification. Portage's depgraph always considers the builder's own
#    "/" bintree (real /etc/portage config) alongside --root=$TARGET's, even for a
#    target-only install, so "/" needs the same GPG trust or that lookup 401s the
#    whole target emerge in stage 30.
#  - sys-apps/systemd[policykit], app-text/xmlto[text], and the other package.use lines
#    below: portage's REQUIRED_USE/slot-operator checks for target packages (--root=$TARGET)
#    get evaluated against whatever's on the builder's own "/" for any package name that
#    also resolves there — even packages not installed there, since it's the plain "/"
#    profile/package.use computation that leaks in, not vardb state (a portage depgraph
#    quirk with multi-root operation). A stock stage3 "/" whose USE doesn't match the
#    target's desktop profile produces phantom slot conflicts and bogus REQUIRED_USE
#    failures (e.g. sys-auth/polkit's target-side install requires systemd[policykit];
#    media-libs/libcanberra's REQUIRED_USE "udev? ( alsa )" reads as unsatisfied because
#    "/" lacks alsa globally). Mirrored per-package rather than as a global USE change on
#    "/" — that cascades into unrelated rebuilds (e.g. flipping introspection globally drags
#    the whole GObject stack in). Packages here that aren't actually installed on "/" only
#    need the package.use line, not a re-emerge.
#    app-text/xmlto[text] is kept as cheap insurance against a docs-toolchain REQUIRED_USE
#    on the target side; retest dropping it (and its --oneshot) after the first green build.
RUN echo 'app-emulation/qemu qemu_softmmu_targets_x86_64 -qemu_softmmu_targets_i386 -qemu_user_targets_x86_64' \
      >> /etc/portage/package.use/builder \
 && echo 'sys-apps/systemd boot ukify policykit' >> /etc/portage/package.use/builder \
 && echo 'app-text/xmlto text' >> /etc/portage/package.use/builder \
 && echo 'media-libs/libcanberra -udev' >> /etc/portage/package.use/builder \
 && echo 'x11-libs/libdrm video_cards_radeon' >> /etc/portage/package.use/builder \
 && echo 'media-libs/mesa vulkan vaapi wayland' >> /etc/portage/package.use/builder \
 && echo 'gnome-extra/gnome-software flatpak -fwupd -malcontent' >> /etc/portage/package.use/builder \
 && echo 'gnome-base/gdm wayland -xdmcp -fprint plymouth' >> /etc/portage/package.use/builder \
 && echo 'gnome-base/librsvg tools' >> /etc/portage/package.use/builder \
 && echo 'gnome-base/gnome-control-center -gnome-online-accounts' >> /etc/portage/package.use/builder \
 && echo 'gnome-extra/evolution-data-server -oauth -kerberos -ldap -weather -vala' >> /etc/portage/package.use/builder \
 && echo 'x11-wm/mutter wayland X screencast' >> /etc/portage/package.use/builder \
 && echo 'media-video/ffmpeg vaapi' >> /etc/portage/package.use/builder \
 && echo 'dev-libs/glib dbus introspection' >> /etc/portage/package.use/builder \
 && echo 'gui-libs/gtk wayland X introspection' >> /etc/portage/package.use/builder \
 && echo 'x11-libs/gtk+ wayland X introspection' >> /etc/portage/package.use/builder \
 && echo 'x11-libs/cairo X' >> /etc/portage/package.use/builder \
 && echo 'sys-auth/polkit gtk introspection' >> /etc/portage/package.use/builder \
 && echo 'x11-libs/libxkbcommon X' >> /etc/portage/package.use/builder \
 && echo 'net-print/cups dbus' >> /etc/portage/package.use/builder \
 && echo 'x11-base/xwayland libei' >> /etc/portage/package.use/builder \
 && echo 'app-crypt/gcr gtk' >> /etc/portage/package.use/builder \
 && echo 'media-libs/libpulse X' >> /etc/portage/package.use/builder \
 && echo 'media-plugins/alsa-plugins pulseaudio' >> /etc/portage/package.use/builder \
 && echo 'media-libs/freetype harfbuzz' >> /etc/portage/package.use/builder \
 && echo 'media-libs/libglvnd X' >> /etc/portage/package.use/builder \
 && echo 'sys-libs/minizip-ng compat' >> /etc/portage/package.use/builder \
 && emerge --quiet-build=y --noreplace --usepkg \
      sys-fs/erofs-utils \
      sys-fs/dosfstools \
      sys-fs/mtools \
      sys-fs/e2fsprogs \
      app-arch/zstd \
      net-misc/rsync \
      sys-kernel/dracut \
      app-emulation/qemu \
      sys-firmware/edk2-bin \
      app-crypt/gnupg \
      sec-keys/openpgp-keys-gentoo-release \
      dev-util/shellcheck-bin \
      gnome-base/librsvg \
      media-fonts/ibm-plex \
      dev-python/pillow \
 && emerge --quiet-build=y --oneshot --usepkg sys-apps/systemd app-text/xmlto \
 && GETUTO_EXTERNAL_REFRESH=0 getuto

# Stages are bind-mounted at /repo and invoked explicitly with bash (the repo may be
# checked out on NTFS with no exec bits — never rely on +x).
WORKDIR /work
ENTRYPOINT ["/bin/bash"]
