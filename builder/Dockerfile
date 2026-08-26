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

# Binary packages for the BUILDER's own "/". This is the builder only, and it is the opposite
# policy from the image: the target has no binhost at all and compiles what it ships (see the
# NB in config/portage/make.conf.in). Nothing installed here reaches the image.
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
# a local mirror only has to be set in one place. Packages whose USE this image overrides below
# (mesa[vulkan], polkit[gtk], the qemu target list, ...) still build from source: the binhost's
# copies were built against the default profile's USE and portage correctly refuses a
# mismatched binpkg.
#
# The two assertions after getuto are the guard for the silent-fallback failure above: they
# fail the image build if FEATURES did not actually pick up getbinpkg, or if getuto produced
# no trust store — the two states in which every emerge below quietly compiles instead.
ARG BINHOST=https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/
RUN printf 'FEATURES="${FEATURES} getbinpkg"\n' >> /etc/portage/make.conf \
 && printf '[gentoo]\npriority = 1\nsync-uri = %s\nlocation = /var/cache/binhost/gentoo\nverify-signature = true\n' \
      "$BINHOST" > /etc/portage/binrepos.conf/gentoo.conf \
 && GETUTO_EXTERNAL_REFRESH=0 getuto \
 && portageq envvar FEATURES | tr ' ' '\n' | grep -qx getbinpkg \
 && test -s /etc/portage/gnupg/pubring.kbx

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
#  - dev-lang/go + dev-lang/rust-bin: BDEPENDs of the container stack (plan/13) — podman and
#    go-md2man are Go, netavark and aardvark-dns are Rust. BDEPEND always installs to the
#    builder's "/", never to $TARGET, so these would arrive on their own during stage 30's
#    target emerge. They are listed HERE anyway for two reasons. First, cost: pulled in ad hoc
#    they are re-resolved against a fresh work volume, while a line in this file is a cached
#    Docker layer served from the binhost. Second, and the real one: virtual/rust is satisfied
#    by EITHER dev-lang/rust or dev-lang/rust-bin, and with neither installed portage is free
#    to pick the from-source one — hours of compiling a toolchain for two 10 MiB binaries.
#    Installing rust-bin first makes the installed provider the one portage keeps.
#  - gnupg + sec-keys/openpgp-keys-gentoo-release + getuto: trust store for binhost
#    signature verification, needed by every emerge that runs against "/" — this one and the
#    buildhost set in stage 30. It also used to be needed for stage 30's TARGET emerge, whose
#    depgraph considers the builder's own "/" bintree (real /etc/portage config) alongside
#    --root=$TARGET's: with the target still on a binhost, portage populated both remotely and
#    an untrusted "/" lookup 401'd the whole thing. That emerge no longer fetches anything
#    remote, but the trust store stays — the builder's own installs are still binary.
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
#
#    KEEP THESE IN SYNC WITH config/portage/package.use/image, verbatim. They are largely
#    redundant with mirror_target_pkg_config(), which writes zz-target-mirror at build time —
#    that file sorts after this one and wins on conflict. Where they matter is the builder's
#    OWN emerge in this Dockerfile, which runs before any mirror exists, and as documentation.
#    Three of these lines had silently drifted from the target's under GNOME, which is worth
#    not reproducing: a mirror that disagrees with what it mirrors is worse than no mirror.
#    The Plasma lines below are copied flag-for-flag from package.use/image (plan/09 §4).
RUN echo 'app-emulation/qemu qemu_softmmu_targets_x86_64 -qemu_softmmu_targets_i386 -qemu_user_targets_x86_64' \
      >> /etc/portage/package.use/builder \
 && echo 'sys-apps/systemd boot ukify policykit pam' >> /etc/portage/package.use/builder \
 && echo 'media-libs/libcanberra -udev' >> /etc/portage/package.use/builder \
 && echo 'x11-libs/libdrm video_cards_radeon' >> /etc/portage/package.use/builder \
 && echo 'media-libs/mesa vulkan vaapi wayland' >> /etc/portage/package.use/builder \
 && echo 'kde-plasma/kwin lock systemd screencast -gamepad -gles2-only -accessibility' >> /etc/portage/package.use/builder \
 && echo 'kde-plasma/plasma-login-sessions wayland -X' >> /etc/portage/package.use/builder \
 && echo 'kde-plasma/plasma-workspace X fontconfig appstream networkmanager policykit systemd screencast ksysguard wallpaper-metadata semantic-desktop -telemetry' >> /etc/portage/package.use/builder \
 && echo 'kde-plasma/plasma-desktop semantic-desktop -webengine -ibus -scim -sdl' >> /etc/portage/package.use/builder \
 && echo 'kde-plasma/discover flatpak -firmware -snap -telemetry -webengine' >> /etc/portage/package.use/builder \
 && echo 'kde-apps/kio-extras samba -mtp -nfs -X taglib -openexr -ios' >> /etc/portage/package.use/builder \
 && echo 'kde-frameworks/kfilemetadata exif pdf ffmpeg taglib -epub -mobi' >> /etc/portage/package.use/builder \
 && echo 'dev-qt/qtbase libproxy icu wayland opengl vulkan cups' >> /etc/portage/package.use/builder \
 && echo 'dev-qt/qtdeclarative opengl vulkan' >> /etc/portage/package.use/builder \
 && echo 'dev-qt/qt5compat icu qml' >> /etc/portage/package.use/builder \
 && echo 'dev-qt/qttools opengl' >> /etc/portage/package.use/builder \
 && echo 'dev-qt/qtmultimedia opengl vulkan qml' >> /etc/portage/package.use/builder \
 && echo 'dev-qt/qtquick3d opengl vulkan' >> /etc/portage/package.use/builder \
 && echo 'kde-frameworks/kconfig qml dbus' >> /etc/portage/package.use/builder \
 && echo 'kde-frameworks/kcoreaddons dbus' >> /etc/portage/package.use/builder \
 && echo 'kde-frameworks/kguiaddons wayland' >> /etc/portage/package.use/builder \
 && echo 'kde-frameworks/kidletime wayland' >> /etc/portage/package.use/builder \
 && echo 'kde-frameworks/kimageformats avif' >> /etc/portage/package.use/builder \
 && echo 'kde-frameworks/kwindowsystem X wayland' >> /etc/portage/package.use/builder \
 && echo 'kde-frameworks/prison qml' >> /etc/portage/package.use/builder \
 && echo 'kde-frameworks/sonnet qml -hunspell -aspell' >> /etc/portage/package.use/builder \
 && echo 'dev-libs/qcoro dbus' >> /etc/portage/package.use/builder \
 && echo 'sys-apps/dbus X' >> /etc/portage/package.use/builder \
 && echo 'net-dns/avahi mdnsresponder-compat' >> /etc/portage/package.use/builder \
 && echo 'media-libs/libva X' >> /etc/portage/package.use/builder \
 && echo 'app-crypt/libsecret -vala' >> /etc/portage/package.use/builder \
 && echo 'app-text/poppler qt6 -cairo' >> /etc/portage/package.use/builder \
 && echo 'dev-libs/appstream qt6' >> /etc/portage/package.use/builder \
 && echo 'dev-libs/libportal qt6 -gtk -vala' >> /etc/portage/package.use/builder \
 && echo 'media-video/ffmpeg vaapi' >> /etc/portage/package.use/builder \
 && echo 'dev-libs/glib dbus introspection' >> /etc/portage/package.use/builder \
 && echo 'gui-libs/gtk wayland X vulkan' >> /etc/portage/package.use/builder \
 && echo 'x11-libs/gtk+ wayland X' >> /etc/portage/package.use/builder \
 && echo 'media-libs/vulkan-loader X wayland' >> /etc/portage/package.use/builder \
 && echo 'x11-libs/cairo X' >> /etc/portage/package.use/builder \
 && echo 'sys-auth/polkit kde -gtk' >> /etc/portage/package.use/builder \
 && echo 'x11-libs/libxkbcommon X' >> /etc/portage/package.use/builder \
 && echo 'net-print/cups dbus' >> /etc/portage/package.use/builder \
 && echo 'x11-base/xwayland libei' >> /etc/portage/package.use/builder \
 && echo 'app-crypt/pinentry qt6 ncurses -gtk -efl -emacs' >> /etc/portage/package.use/builder \
 && echo 'x11-misc/xdg-utils -perl -gnome' >> /etc/portage/package.use/builder \
 && echo 'x11-misc/xdg-user-dirs -gtk' >> /etc/portage/package.use/builder \
 && echo 'net-fs/samba client' >> /etc/portage/package.use/builder \
 && echo 'net-libs/ngtcp2 gnutls' >> /etc/portage/package.use/builder \
 && echo 'net-wireless/wpa_supplicant -gui dbus' >> /etc/portage/package.use/builder \
 && echo 'media-libs/libpulse X' >> /etc/portage/package.use/builder \
 && echo 'media-plugins/alsa-plugins pulseaudio' >> /etc/portage/package.use/builder \
 && echo 'media-libs/freetype harfbuzz' >> /etc/portage/package.use/builder \
 && echo 'media-libs/libglvnd X' >> /etc/portage/package.use/builder \
 && echo 'sys-libs/minizip-ng compat' >> /etc/portage/package.use/builder \
 && echo 'app-text/xmlto text' >> /etc/portage/package.use/builder \
 && echo 'gnome-base/librsvg tools' >> /etc/portage/package.use/builder \
 && emerge --quiet-build=y --noreplace --usepkg --getbinpkg \
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
      dev-lang/go \
      dev-lang/rust-bin \
 && emerge --quiet-build=y --oneshot --usepkg --getbinpkg sys-apps/systemd app-text/xmlto \
 && GETUTO_EXTERNAL_REFRESH=0 getuto

# Stages are bind-mounted at /repo and invoked explicitly with bash (the repo may be
# checked out on NTFS with no exec bits — never rely on +x).
WORKDIR /work
ENTRYPOINT ["/bin/bash"]
