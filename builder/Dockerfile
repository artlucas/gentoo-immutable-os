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
#  - gnupg: release signing verification (stage 80)
RUN echo 'app-emulation/qemu qemu_softmmu_targets_x86_64 -qemu_softmmu_targets_i386 -qemu_user_targets_x86_64' \
      >> /etc/portage/package.use/builder \
 && echo 'sys-apps/systemd boot ukify' >> /etc/portage/package.use/builder \
 && emerge --quiet-build=y --noreplace \
      sys-fs/erofs-utils \
      sys-fs/dosfstools \
      sys-fs/mtools \
      sys-fs/e2fsprogs \
      app-arch/zstd \
      net-misc/rsync \
      sys-kernel/dracut \
      app-emulation/qemu \
      sys-firmware/edk2-ovmf-bin \
      app-crypt/gnupg \
      dev-util/shellcheck-bin \
 && emerge --quiet-build=y --oneshot sys-apps/systemd

# Stages are bind-mounted at /repo and invoked explicitly with bash (the repo may be
# checked out on NTFS with no exec bits — never rely on +x).
WORKDIR /work
ENTRYPOINT ["/bin/bash"]
