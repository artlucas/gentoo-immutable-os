#!/bin/bash
# shellcheck disable=SC2154  # moddir/initdir/systemdsystemunitdir come from dracut
# dracut module: make systemd-repart.service work in a DRACUT initrd (plan/01 first-boot growth).
#
# Upstream's systemd-repart.service is written for the systemd/mkosi initrd, where /sysusr/usr is
# already mounted by the time initrd-usr-fs.target is reached. dracut mounts neither /sysusr nor
# /sysroot that early — repart runs before udev has even started — so repart's find_root() probes
# /sysusr/usr, then /sysroot/usr, finds neither, and fails with
#
#     Failed to determine backing device of /sysroot/usr: No such file or directory
#
# exiting 1. The unit tolerates 76 ("no root block device") and 77 ("no GPT") but not 1, so the
# service fails, the initrd goes to emergency, and rd.emergency=reboot turns that into an endless
# reboot loop with no other message on the console.
#
# The drop-in orders it after sysroot.mount, which is where /sysroot/usr becomes resolvable.
# It stays Before=initrd-root-fs.target, so it still runs before /var is mounted and its
# x-systemd.growfs grows the filesystem into the partition repart just extended.
#
# This has to be an initrd-only drop-in, hence a dracut module rather than a file in the image:
# systemd-repart.service ALSO runs on the booted system (harmlessly, reporting "No changes"),
# and there Requires=sysroot.mount would refer to a unit that does not exist.

check() {
    return 0
}

depends() {
    echo systemd-repart
}

install() {
    inst_simple "$moddir/10-sysroot.conf" \
        "$systemdsystemunitdir/systemd-repart.service.d/10-sysroot.conf"
}
