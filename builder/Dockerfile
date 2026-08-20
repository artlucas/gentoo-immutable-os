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

# Host-side tools (never enter the target):
#  - erofs/vfat/ext4 + mtools: loopless image assembly (stage 60)
#  - dracut: initrd for the UKI (stage 40)
#  - qemu + OVMF: boot tests (stage 70)
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
 && echo 'gnome-base/gdm wayland -xdmcp -fprint -plymouth' >> /etc/portage/package.use/builder \
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
 && emerge --quiet-build=y --noreplace \
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
 && emerge --quiet-build=y --oneshot sys-apps/systemd app-text/xmlto \
 && GETUTO_EXTERNAL_REFRESH=0 getuto

# Stages are bind-mounted at /repo and invoked explicitly with bash (the repo may be
# checked out on NTFS with no exec bits — never rely on +x).
WORKDIR /work
ENTRYPOINT ["/bin/bash"]
