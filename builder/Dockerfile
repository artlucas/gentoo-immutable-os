# Builder container: full Gentoo with toolchain + image-assembly tools.
# The target rootfs is emerged from inside this container with --root= (plan/02).
#
# Pin via: docker build --build-arg BASE="gentoo/stage3:amd64-systemd@sha256:<digest>"
# (BUILDER_DIGEST in config/build.conf; build.sh passes it through).
ARG BASE=gentoo/stage3:amd64-systemd
FROM ${BASE}

# The ebuild repo, pinned to a dated rsync snapshot (plan/15).
#
# This RUN used to be a bare `emerge-webrsync`, which was broken in two ways at once: it took
# whatever the mirror served that day, and it had NO CACHE BUSTER, so the layer never
# invalidated. The tree this builder actually used was "whenever someone last rebuilt the
# image" — and since stage 10's revert ran inside a `docker run --rm` whose /var/db/repos was
# this layer rather than a volume, the revert was thrown away and nothing anywhere noticed.
#
# Naming SNAPSHOT_DATE as an ARG immediately above the RUN fixes the second half: the layer is
# now keyed on the pin, so bumping the pin rebuilds it.
#
# It is deliberately NOT a plain download of a git forge tarball. That was tried:
# github.com/gentoo-mirror/gentoo is the DEVELOPMENT repo with metadata/md5-cache added, so its
# Manifests carry only DIST lines while layout.conf says thin-manifests = false, and portage
# refuses to merge ebuilds it cannot find listed. webrsync fetches a full-Manifest rsync
# snapshot and verifies upstream's digest and GPG signature before unpacking.
#
# At run time /var/db/repos is a named volume; Docker seeds an empty one from this layer, so
# this is the tree's first copy rather than a duplicate of it. Stage 10 reconciles the volume
# against the pin on every run, for the case where the volume is NOT empty and NOT current.
ARG SNAPSHOT_DATE
RUN test -n "$SNAPSHOT_DATE" || { echo "SNAPSHOT_DATE build-arg is required" >&2; exit 1; } \
 && emerge-webrsync --revert="$SNAPSHOT_DATE" \
 && test -d /var/db/repos/gentoo/metadata/md5-cache \
 && test -f /var/db/repos/gentoo/metadata/timestamp.chk \
 && grep -q '^EBUILD ' /var/db/repos/gentoo/sys-apps/systemd/Manifest

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
#    config/branding to PNG (stage 40). Both are BUILD tools and never enter the image — that
#    is the whole point: the splash ships as pre-composited pixels, so no font, no text engine
#    and no image decoder has to. They live here rather than in config/portage/sets/buildhost
#    because that set is emerged in stage 30, and every stage runs in its own --rm container,
#    so a stage-30 install is gone by stage 40.
#  - dev-python/pillow: composes BOTH shipped splash artefacts from those PNGs (stage 40,
#    config/branding/make-splash-assets.py) — the systemd-stub .splash bitmap and the KMS
#    splash's tile container. rsvg-convert can emit neither: its formats are png/pdf/ps/svg,
#    while BMP is the only container the EFI stub reads and the tiles are raw BGRX. Named
#    explicitly because it was already present here transitively, and a dependency that arrives
#    by accident is one a graph change can remove by accident.
#  - gcc (from the stage3): compiles config/splash/splash.c -static into the image (stage 40).
#    The image itself has no compiler and stage 30 never chroots, so the splash cannot be built
#    in the target; -static is what makes a binary built here safe to run there. See plan/14.
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
# mkdir first: a stage3 ships /etc/portage/package.use as a directory but has no
# /etc/portage/sets at all, so the redirect that writes the request set below would fail.
RUN mkdir -p /etc/portage/sets \
 && echo 'app-emulation/qemu qemu_softmmu_targets_x86_64 -qemu_softmmu_targets_i386 -qemu_user_targets_x86_64' \
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
 && printf '%s\n' \
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
      > /etc/portage/sets/builder-request

# The atom list above is the REQUEST — what a human asked for, with all the reasoning attached.
# builder.lock is the RESOLUTION — those atoms plus the ~480 the binhost pulled in behind them,
# every one at an exact version (plan/15 layer 3). dracut, systemd/ukify and erofs-utils build
# the shipped initrd, UKI and root filesystem, so leaving the builder's own toolchain floating
# leaves a real hole in "two runs from the same config produce the same image".
#
# Both are kept, deliberately. The request is what scripts/relock.sh --builder re-resolves from
# and is where the per-package justifications live; deleting it in favour of the lock would
# throw away the only statement of intent. The lock is what actually gets emerged.
#
# ONE FILE, not the directory. Docker keys a COPY layer on the content of everything copied, so
# `COPY config/portage/lock/` would invalidate this layer — and the ~1 hour of source builds
# behind it — whenever image.lock changed, despite the builder never reading image.lock. That
# would put an hour on every `relock.sh --security`, which is the operation this whole design
# wants to be cheap. builder.lock is committed (empty is fine when bootstrapping a new builder;
# the -s test below falls back to @builder-request), so a single-file COPY is safe.
#
# On a first build from the pinned BUILDER_DIGEST the stage3's own @system packages already
# match the lock exactly — the lock was generated from a builder built on that base — so those
# 480 atoms resolve to "nothing to do" and only the tools are installed. When the base digest
# moves they will not match, and that is precisely when the builder wants relocking.
COPY config/portage/lock/builder.lock /tmp/immos-lock/builder.lock
RUN if [ -s /tmp/immos-lock/builder.lock ]; then \
      grep -v '^#' /tmp/immos-lock/builder.lock | sed '/^$/d' > /etc/portage/sets/locked-builder; \
      SET=@locked-builder; \
      echo "builder: emerging $SET ($(wc -l < /etc/portage/sets/locked-builder) pinned atoms)"; \
    else \
      SET=@builder-request; \
      echo "builder: no builder.lock — emerging $SET unpinned (bootstrap; relock afterwards)"; \
    fi \
 && emerge --quiet-build=y --noreplace --usepkg --getbinpkg "$SET" \
 && emerge --quiet-build=y --oneshot --usepkg --getbinpkg sys-apps/systemd app-text/xmlto \
 && GETUTO_EXTERNAL_REFRESH=0 getuto \
 && rm -rf /tmp/immos-lock

# Stages are bind-mounted at /repo and invoked explicitly with bash (the repo may be
# checked out on NTFS with no exec bits — never rely on +x).
WORKDIR /work
ENTRYPOINT ["/bin/bash"]
