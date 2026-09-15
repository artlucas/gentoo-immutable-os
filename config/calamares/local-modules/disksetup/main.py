#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# disksetup — write the GPT and make the two filesystems there are to make (plan/24).
#
# Replaces Calamares' `partition` module, whose view step and jobs could not be separated: a view
# step owns its jobs(), so the page and the partitioner are one module and replacing one replaces
# the other. The page is `disk`, a compiled view module in config/portage/overlay; this is the
# half that touches the disk.
#
# WHAT IT DOES, and it is short because installing this distro is `dd` rather than
# unpack-and-configure (plan/16 §5.1):
#
#   1. refuse, loudly, unless the target is a whole disk that is not the one we booted from
#   2. unmount everything on it — a desktop session automounts what it finds
#   3. wipe the old signatures, write the new GPT with sfdisk
#   4. mkfs the ESP and /var. The two root slots are left UNFORMATTED, because what goes in them
#      is an EROFS image written byte-for-byte by `imagedeploy`
#   5. publish `partitions` into GlobalStorage, which is the contract the rest of the sequence
#      was already written against
#
# THE GPT COMES FROM lib/layout.sh, WHICH IS THE PIPELINE'S OWN (plan/24 §4). This module does not
# describe a partition layout; it runs /usr/libexec/<id>-disk-layout, which stage 40 installs
# verbatim from scripts/lib/layout.sh — the same file, the same two functions, that stage 60 uses
# to build the factory .img. plan/16 §3.4 requires an installed machine to be indistinguishable
# from one dd'd from that image, and the previous arrangement kept that promise by having
# tests/test-installer.sh compare a YAML block against a shell function, label by label. One file
# cannot disagree with itself.
#
# WHAT IS DELIBERATELY NOT HERE: any notion of a user-chosen layout. There is no swap (plan/16 §6
# is Phase B), no LUKS (plan/24 §7 draws the control and disables it), no filesystem choice and no
# manual partitioning. The page offers a disk and nothing else, and this job writes the one layout
# this distro has.

import json
import os
import re
import subprocess
import time

import libcalamares

# `libcalamares.utils.x`, not `from libcalamares.utils import x`. The submodule is registered by
# PyImport_AddModule from C++ rather than being a real package, and every stock module reaches it
# this way — matching them is cheaper than finding out where the difference bites.
debug = libcalamares.utils.debug
warning = libcalamares.utils.warning

import gettext

_ = gettext.translation(
    "calamares-python",
    localedir=libcalamares.utils.gettext_path(),
    languages=libcalamares.utils.gettext_languages(),
    fallback=True,
).gettext


def pretty_name():
    return _("Preparing the disk.")


class SetupError(Exception):
    """A failure with a message already fit for the user."""

    def __init__(self, title, message):
        super().__init__(message)
        self.title = title
        self.message = message


def sh(cmd, **kwargs):
    """subprocess.run with check=True and the command logged.

    subprocess rather than libcalamares.utils.host_env_process_output, for the same reason
    imagedeploy uses it: these run on the HOST — the live system — against a device node, and the
    failure text should be this module's business rather than a generic "job returned non-zero".
    """
    debug("running: {}".format(" ".join(cmd)))
    return subprocess.run(cmd, check=True, **kwargs)


def partition_node(disk, number):
    """/dev/sda -> /dev/sda1, /dev/nvme0n1 -> /dev/nvme0n1p1.

    The rule is the kernel's and it is about the NAME, not the transport: a partition of a device
    whose name ends in a digit gets a 'p' separator, so that nvme0n1 + 1 cannot be read back as
    nvme0n11. `imagebootloader` splits the same names in the other direction and its comment says
    the same thing from the other side.
    """
    return "{}p{}".format(disk, number) if re.search(r"\d$", disk) else "{}{}".format(disk, number)


def root_source():
    """The device node the live root is mounted from, or None.

    /proc/mounts rather than findmnt: no subprocess, and nothing to parse but whitespace. The
    fourth field is options and the second is the mount point, which is the one being matched.
    """
    try:
        with open("/proc/mounts", "r", encoding="utf-8") as f:
            for line in f:
                fields = line.split()
                if len(fields) >= 2 and fields[1] == "/":
                    return fields[0]
    except OSError as e:
        warning("cannot read /proc/mounts: {}".format(e))
    return None


def disk_of(node):
    """The /sys/block directory that holds `node`, or None.

    Containment, not string surgery: a partition of disk D is always a directory INSIDE
    /sys/block/D, so this needs no rule about which names take a 'p' and which do not. The disk
    page's liveMediumDisk() makes the same test in C++ and its comment explains what goes wrong
    with the trailing-digits version.
    """
    if not node:
        return None
    name = os.path.basename(node)
    try:
        disks = os.listdir("/sys/block")
    except OSError:
        return None
    for d in disks:
        if name == d or os.path.exists("/sys/block/{}/{}".format(d, name)):
            return d
    return None


def mounts_on(disk):
    """Every (source, mountpoint) in /proc/mounts backed by a partition of `disk`.

    A Plasma session automounts what it finds, so by the time anybody reaches this page the
    target's NTFS partition may well be mounted at /run/media/live/Windows. sfdisk will happily
    rewrite the table underneath it and the kernel will then refuse to re-read it, which produces
    an install that appears to work and writes the payload into the old partition offsets.
    """
    out = []
    try:
        with open("/proc/mounts", "r", encoding="utf-8") as f:
            for line in f:
                fields = line.split()
                if len(fields) < 2 or not fields[0].startswith("/dev/"):
                    continue
                if disk_of(fields[0]) == disk:
                    out.append((fields[0], fields[1]))
    except OSError as e:
        warning("cannot read /proc/mounts: {}".format(e))
    return out


def swaps_on(disk):
    """Active swap devices that are partitions of `disk`. /proc/swaps, same reasoning."""
    out = []
    try:
        with open("/proc/swaps", "r", encoding="utf-8") as f:
            next(f, None)  # the header
            for line in f:
                fields = line.split()
                if fields and fields[0].startswith("/dev/") and disk_of(fields[0]) == disk:
                    out.append(fields[0])
    except (OSError, StopIteration) as e:
        warning("cannot read /proc/swaps: {}".format(e))
    return out


def disk_size_bytes(disk):
    """Capacity from sysfs, in bytes.

    ALWAYS 512-byte units, whatever the drive's own sector size: /sys/block/*/size is documented
    in 512-byte sectors and does not follow queue/logical_block_size. A 4Kn disk read through the
    logical size would appear eight times its real capacity — and would pass a minimum-size check
    it should have failed. The disk page reads it the same way, and says so.
    """
    with open("/sys/block/{}/size".format(disk), "r", encoding="utf-8") as f:
        return int(f.read().strip()) * 512


def settle_for(nodes, timeout=20.0):
    """Wait for udev to create every node in `nodes`.

    `sfdisk` tells the kernel about the new table and udev creates the nodes, asynchronously. The
    next thing this module does is mkfs one of them, so "the device is not there yet" is a real
    and intermittent failure — the worst kind to debug from a stranger's photograph of a screen.
    """
    subprocess.run(["udevadm", "settle", "--timeout=10"], check=False)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        missing = [n for n in nodes if not os.path.exists(n)]
        if not missing:
            return
        time.sleep(0.25)
    raise SetupError(
        _("Disk error"),
        _("The partitions were written but did not appear as devices: {!s}. The disk may have "
          "been removed.").format(", ".join(n for n in nodes if not os.path.exists(n))),
    )


def check_target(device, conf):
    """Everything that must be true before a single byte is written. Raises SetupError.

    THIS IS THE FUNCTION THAT PROTECTS DATA, and it re-asks questions the page already asked. That
    is deliberate: the page's answers travel through GlobalStorage, and by the time they get here
    they are a string. A job that erases a disk should not take a string's word for it.
    """
    if not device:
        raise SetupError(
            _("Internal error"),
            _("No disk was chosen. The installer's disk page is supposed to have made this "
              "impossible — it does not enable Next until a disk is selected and confirmed."),
        )
    if not libcalamares.globalstorage.value("diskConfirmed"):
        raise SetupError(
            _("Internal error"),
            _("The installer reached the disk-writing step without a confirmed disk. Nothing has "
              "been written."),
        )
    if not os.path.exists(device):
        raise SetupError(
            _("Disk error"),
            _("{!s} is no longer present. If you removed a disk, start the installer "
              "again.").format(device),
        )

    disk = os.path.basename(device)
    if not os.path.isdir("/sys/block/{}".format(disk)):
        # A partition, a device-mapper node or something else that is not a whole disk. The page
        # only ever offers whole disks, so this means the value was not the page's.
        raise SetupError(
            _("Internal error"),
            _("{!s} is not a whole disk. This installer only ever installs to a whole "
              "disk.").format(device),
        )

    live = disk_of(root_source())
    if live is None:
        # The page says the same thing in its own log: if the live root has no device node we
        # cannot identify the medium, and the one check that protects data cannot be made.
        raise SetupError(
            _("Internal error"),
            _("The installer cannot tell which disk it is running from, so it will not erase any "
              "disk. This should not happen on this installation medium."),
        )
    if disk == live:
        raise SetupError(
            _("Disk error"),
            _("{!s} is the disk this installer is running from. It cannot be erased while it is "
              "in use.").format(device),
        )

    minimum_gb = float(conf.get("minimumDiskSize") or 0)
    size = disk_size_bytes(disk)
    if minimum_gb > 0 and size < minimum_gb * 1000 * 1000 * 1000:
        raise SetupError(
            _("Disk error"),
            _("{!s} is too small: {:.1f} GB, and at least {:.0f} GB is needed.").format(
                device, size / 1e9, minimum_gb),
        )
    return disk, size


def release_disk(disk):
    """Unmount and swapoff everything on the target, or refuse to continue.

    ORDERED LONGEST PATH FIRST, so /run/media/live/Data/thing comes off before its parent. Sorting
    by length is the cheap version of a mount-tree walk and is correct for the nesting a live
    session can actually produce.
    """
    for node in swaps_on(disk):
        try:
            sh(["swapoff", node])
        except subprocess.CalledProcessError as e:
            raise SetupError(
                _("Disk error"),
                _("{!s} is in use as swap and could not be released.").format(node),
            ) from e

    for node, point in sorted(mounts_on(disk), key=lambda m: len(m[1]), reverse=True):
        debug("unmounting {} from {}".format(node, point))
        try:
            sh(["umount", point])
        except subprocess.CalledProcessError as e:
            raise SetupError(
                _("Disk error"),
                _("{!s} is mounted at {!s} and could not be unmounted, so the disk has not been "
                  "changed. Close anything using it and try again.").format(node, point),
            ) from e

    # Whatever is left holding the device open. `lsof` is not on this medium and a busy device is
    # a failure sfdisk reports clearly, so this is only a log line — but it is the log line that
    # explains the failure that follows.
    remaining = mounts_on(disk)
    if remaining:
        warning("still mounted after release: {}".format(remaining))


def layout_script(conf, device, disk_bytes):
    """Ask lib/layout.sh for the sfdisk script. The pipeline's own function, on the medium.

    MiB, floored: the helper works in whole mebibytes, and a floor is what keeps the layout inside
    the disk rather than one megabyte past the end of it.
    """
    helper = conf.get("layoutHelper") or ""
    if not os.path.exists(helper):
        raise SetupError(
            _("Configuration Error"),
            _("The disk layout helper is missing from this installation medium: {!s}. Stage 40 "
              "installs it from scripts/lib/layout.sh.").format(helper),
        )
    cmd = [
        helper, "sfdisk",
        "--disk-mib", str(disk_bytes // (1024 * 1024)),
        "--esp-mib", str(int(conf["espSizeMiB"])),
        "--slot-mib", str(int(conf["rootSlotSizeMiB"])),
        "--version", str(conf["version"]),
        "--min-var-mib", str(int(conf.get("minVarMiB") or 4096)),
    ]
    debug("running: {}".format(" ".join(cmd)))
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SetupError(
            _("Disk error"),
            _("The disk layout could not be computed for {!s}:\n{!s}").format(
                device, proc.stderr.strip()),
        )

    script = proc.stdout
    # The one string in this script that the installed system's identity depends on: the UKI's
    # cmdline says root=PARTLABEL=root_<version>, baked in at build time on every machine. If the
    # helper and this medium's payload ever disagree about it, the install completes and the
    # machine does not boot — so it is checked here, where the message can still name the cause.
    want = conf.get("rootPartLabel") or ""
    if want and 'name="{}"'.format(want) not in script:
        raise SetupError(
            _("Internal error"),
            _("The disk layout does not create the partition this medium installs into "
              "({!s}). Nothing has been written to {!s}.").format(want, device),
        )
    return script


def write_table(device, script):
    """Wipe the old signatures and write the new GPT."""
    # wipefs FIRST. sfdisk writes a GPT; it does not remove a stale MBR, an old LVM header or a
    # filesystem superblock sitting where the new ESP will be — and a partition that still carries
    # the signature of whatever was there before is one blkid will report as the old filesystem,
    # to systemd's generators among others.
    sh(["wipefs", "--all", "--force", device])
    debug("sfdisk script for {}:\n{}".format(device, script))
    proc = subprocess.run(["sfdisk", "--wipe", "always", "--quiet", device],
                          input=script, text=True, capture_output=True)
    if proc.returncode != 0:
        raise SetupError(
            _("Disk error"),
            _("The partition table could not be written to {!s}:\n{!s}").format(
                device, proc.stderr.strip()),
        )
    # Tell the kernel, then wait for udev. --reread rather than partprobe: it is part of the same
    # util-linux that just wrote the table, and this medium has it by construction.
    subprocess.run(["sfdisk", "--reread", device], check=False, capture_output=True)


def run():
    """Partition the chosen disk and report what was made."""
    conf = libcalamares.job.configuration
    device = (libcalamares.globalstorage.value("diskDevice") or "").strip()

    try:
        disk, size = check_target(device, conf)
        libcalamares.job.setprogress(0.1)

        release_disk(disk)
        libcalamares.job.setprogress(0.2)

        write_table(device, layout_script(conf, device, size))
        libcalamares.job.setprogress(0.5)

        # The four partitions, in the order lib/layout.sh emits them. This mapping is the ONE
        # place in this module that knows which partition is which, and it is positional because
        # the layout is fixed — see the module header on why there is no user-chosen layout to
        # discover here.
        esp = partition_node(device, 1)
        root_a = partition_node(device, 2)
        root_b = partition_node(device, 3)
        var = partition_node(device, 4)
        settle_for([esp, root_a, root_b, var])
        libcalamares.job.setprogress(0.6)

        # The ESP, and then /var. The two root slots are NOT formatted: imagedeploy writes an
        # EROFS image into slot A byte-for-byte, and slot B ships as zeros for systemd-sysupdate
        # to claim. A mkfs here would be a filesystem that gets overwritten a step later.
        #
        # The labels match the ones stage 60 gives the factory image's filesystems (`mkfs.ext4 -L
        # var`, `mkfs.vfat -n ESP`). Nothing reads them — /etc/fstab finds both partitions by
        # PARTLABEL — but "indistinguishable from an image dd'd to the disk" is the property this
        # whole installer is built around, and a filesystem label is part of what `lsblk` shows
        # somebody comparing the two.
        sh(["mkfs.vfat", "-F32", "-n", str(conf.get("espLabel") or "ESP"), esp],
           capture_output=True)
        libcalamares.job.setprogress(0.75)
        sh(["mkfs.ext4", "-q", "-F", "-L", str(conf.get("varLabel") or "var"), var],
           capture_output=True)
        libcalamares.job.setprogress(0.9)

        # THE CONTRACT WITH THE REST OF THE SEQUENCE, and it is upstream's shape on purpose.
        # `imagedeploy` looks for the root slot by `partlabel` and for the other two by
        # `mountPoint`; `imagebootloader` looks for /efi the same way. Both were written against
        # what KPMcore used to publish here, and neither needed a line changed when this module
        # replaced it — which is the test of whether the replacement is honest.
        partitions = [
            {"device": esp, "mountPoint": "/efi", "fs": "fat32", "fsName": "fat32",
             "partlabel": "esp", "claimed": True, "uuid": ""},
            {"device": root_a, "mountPoint": None, "fs": "unformatted", "fsName": "unformatted",
             "partlabel": str(conf.get("rootPartLabel") or ""), "claimed": True, "uuid": ""},
            {"device": root_b, "mountPoint": None, "fs": "unformatted", "fsName": "unformatted",
             "partlabel": "_empty", "claimed": True, "uuid": ""},
            {"device": var, "mountPoint": "/var", "fs": "ext4", "fsName": "ext4",
             "partlabel": "var", "claimed": True, "uuid": ""},
        ]
        libcalamares.globalstorage.insert("partitions", partitions)
        # Upstream's `partition` module publishes this and the stock bootloader module reads it.
        # We do not run that module, but `summary` and any future stock step do look for it, and
        # a medium that is UEFI-only by construction should say so rather than leave it unset.
        libcalamares.globalstorage.insert("firmwareType", "efi")
        libcalamares.job.setprogress(1.0)

        debug("partitioned {}: {}".format(device, json.dumps(partitions)))
        return None

    except SetupError as e:
        return (e.title, e.message)
    except subprocess.CalledProcessError as e:
        return (
            _("Disk error"),
            _("A command failed while preparing {!s}:\n{!s}").format(
                device, " ".join(e.cmd) if isinstance(e.cmd, list) else str(e.cmd)),
        )
    except OSError as e:
        return (_("Disk error"), _("{!s} could not be prepared: {!s}").format(device, e))
