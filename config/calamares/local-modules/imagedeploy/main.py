#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# imagedeploy — write the payload to disk and mount the result.
#
# Replaces Calamares' `unpackfs` AND `mount` (plan/16 §5.3). One module rather than two because
# the two halves are one ordering: the root filesystem has to BE on the partition before the
# partition can be mounted, and the /etc overlay has to go on before any stock module writes to
# /etc. Splitting that across two modules would put the ordering in settings.conf, where it
# would look like a preference.
#
# What makes this short: installing this distro is not unpack-and-configure. There is no squashfs
# to rsync, no package manager to run and no bootloader to generate — the root filesystem is an
# EROFS image built by the pipeline, and installing it is copying it onto a partition.
#
#   1. write <payload>/root.erofs into the root_<version> partition, byte for byte
#   2. mount it read-only, and /var over it
#   3. unpack the var template — overlay skeleton, homes, the Flatpak store
#   4. mount /etc as an overlay whose upper lives on /var, exactly as the initrd does
#   5. mount the ESP and the API filesystems, and hand rootMountPoint to the stock modules
#
# Step 4 is the one that matters. It is the same incantation as
# config/rootfs/usr/lib/dracut/modules.d/90etc-overlay/etc-overlay.sh, including mounting the
# overlay onto its own lowerdir — and with it in place, Calamares' stock `locale`, `keyboard`,
# `users` and `removeuser` modules write to /etc/... exactly as they would on a mutable distro,
# and the writes land in the upper on /var because that is what the mount does. No patched
# modules anywhere in this installer (plan/16 §5.2).

import json
import os
import subprocess
import tempfile

import libcalamares
from libcalamares.utils import debug, warning

import gettext

_ = gettext.translation(
    "calamares-python",
    localedir=libcalamares.utils.gettext_path(),
    languages=libcalamares.utils.gettext_languages(),
    fallback=True,
).gettext


# 8 MiB: large enough that the per-call overhead vanishes against the write, small enough that
# the progress bar moves ~340 times over a 2.7 GiB image rather than in four jumps.
CHUNK = 8 * 1024 * 1024

# EROFS superblock magic, little-endian, at offset 1024. The same four bytes stage 60 checks
# after it dd's the image into the .img — see the verify block in scripts/stages/60-image.sh.
EROFS_MAGIC = bytes((0xE2, 0xE1, 0xF5, 0xE0))
EROFS_MAGIC_OFFSET = 1024


def pretty_name():
    return _("Writing the system image to disk.")


class DeployError(Exception):
    """A failure with a message already fit for the user."""

    def __init__(self, title, message):
        super().__init__(message)
        self.title = title
        self.message = message


def sh(cmd, **kwargs):
    """subprocess.run with check=True and the command logged.

    subprocess rather than libcalamares.utils.host_env_process_output for the same reason the
    stock `mount` module uses it: these calls are on the HOST (the live system), several of them
    run for minutes, and the timeout and the failure text should be this module's business.
    """
    debug("running: {}".format(" ".join(cmd)))
    return subprocess.run(cmd, check=True, **kwargs)


def find_partitions(root_label):
    """Pick the three partitions this install needs out of GlobalStorage.

    BY LABEL AND MOUNT POINT, never by index. The partition module reports every partition on
    every touched device in on-disk order, and an index would silently follow whatever the
    layout in partition.conf happens to be today.

    The root slot is found by its PARTLABEL because that label IS the system's identity: the UKI
    cmdline says root=PARTLABEL=root_<version>, baked in at build time. If the label the
    partition module wrote does not match the one this installer's payload expects, the machine
    would install cleanly and then fail to boot with "cannot find root" — so it is checked here,
    where the error can still name the cause.
    """
    partitions = libcalamares.globalstorage.value("partitions")
    if not partitions:
        raise DeployError(
            _("Configuration Error"),
            _("No partitions are defined for <pre>{!s}</pre> to use.").format("imagedeploy"),
        )

    found = {"root": None, "var": None, "esp": None}
    for p in partitions:
        if p.get("partlabel") == root_label:
            found["root"] = p
        elif p.get("mountPoint") == "/var":
            found["var"] = p
        elif p.get("mountPoint") == "/efi":
            found["esp"] = p

    missing = [k for k, v in found.items() if v is None]
    if missing:
        have = ", ".join(
            "{}[{}]".format(p.get("device"), p.get("partlabel") or p.get("mountPoint") or "-")
            for p in partitions
        )
        raise DeployError(
            _("Internal error"),
            _(
                "The partitioner did not produce the expected layout: {!s} missing. "
                "Expected a partition labelled '{!s}', one mounted at /var and one at /efi. "
                "Got: {!s}"
            ).format(", ".join(missing), root_label, have),
        )
    return found


def sha256_of(path, progress=None):
    import hashlib

    h = hashlib.sha256()
    total = os.path.getsize(path)
    done = 0
    with open(path, "rb") as f:
        while True:
            chunk = f.read(CHUNK)
            if not chunk:
                break
            h.update(chunk)
            done += len(chunk)
            if progress and total:
                progress(done / total)
    return h.hexdigest()


def write_image(source, device, progress):
    """Copy `source` onto the block device `device`, with progress.

    A Python loop rather than `dd`: dd reports progress only to a tty, and the thing a user
    stares at for three minutes should have a moving bar. os.fsync at the end (not just close)
    because the next thing that happens is a mount of this very device.
    """
    total = os.path.getsize(source)
    debug("writing {} ({} bytes) to {}".format(source, total, device))

    written = 0
    with open(source, "rb") as src, open(device, "r+b") as dst:
        while True:
            chunk = src.read(CHUNK)
            if not chunk:
                break
            dst.write(chunk)
            written += len(chunk)
            progress(written / total)
        dst.flush()
        os.fsync(dst.fileno())
    return written


def check_erofs_magic(device):
    """Read back the superblock. Cheap, and it is the difference between 'installed' and
    'installed something'.

    Writing to a block device fails silently in more ways than writing to a file does — a stick
    that reports a size it does not have, a partition shorter than the image. Stage 60 makes the
    same check against the .img it assembles, for the same reason.
    """
    with open(device, "rb") as f:
        f.seek(EROFS_MAGIC_OFFSET)
        magic = f.read(4)
    if magic != EROFS_MAGIC:
        raise DeployError(
            _("Installation failed"),
            _(
                "The root filesystem did not verify after writing to {!s}: expected the EROFS "
                "signature at offset {!s}, found {!s}. The install medium or the target disk "
                "may be faulty."
            ).format(device, EROFS_MAGIC_OFFSET, magic.hex()),
        )


def mount(source, target, fstype=None, options=None, mkdir=True):
    if mkdir:
        os.makedirs(target, exist_ok=True)
    cmd = ["mount"]
    if fstype:
        cmd += ["-t", fstype]
    if options:
        cmd += ["-o", options]
    cmd += [source, target]
    sh(cmd)


def run():
    conf = libcalamares.job.configuration
    payload_dir = conf.get("payloadDir", "/var/lib/install")
    root_label = conf.get("rootPartLabel")
    if not root_label:
        return (
            _("Configuration Error"),
            _("<pre>{!s}</pre> does not name rootPartLabel.").format("imagedeploy"),
        )

    root_image = os.path.join(payload_dir, conf.get("rootImage", "root.erofs"))
    var_template = os.path.join(payload_dir, conf.get("varTemplate", "var.tar.zst"))
    manifest_path = os.path.join(payload_dir, conf.get("manifest", "manifest.json"))

    try:
        parts = find_partitions(root_label)

        # ---- 0. the payload is there, and it is the payload we think ------------------------
        for label, path in (("root image", root_image), ("manifest", manifest_path)):
            if not os.path.isfile(path):
                raise DeployError(
                    _("Installation failed"),
                    _("The {!s} is missing from the install medium ({!s}).").format(label, path),
                )
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)

        if conf.get("verifyPayload", True):
            libcalamares.job.setprogress(0.0)
            expected = manifest.get("root_erofs", {}).get("sha256")
            if expected:
                debug("verifying {} against the manifest".format(root_image))
                actual = sha256_of(
                    root_image, lambda f: libcalamares.job.setprogress(f * 0.10)
                )
                if actual != expected:
                    raise DeployError(
                        _("Installation failed"),
                        _(
                            "The system image on the install medium is corrupt: its checksum is "
                            "{!s}, the manifest says {!s}. Write the installer to the USB stick "
                            "again."
                        ).format(actual[:16], expected[:16]),
                    )
            else:
                warning("manifest carries no sha256 for the root image; skipping verification")

        # ---- 1. the root filesystem, byte for byte ------------------------------------------
        # This is the install. Everything after it is mounting and identity.
        write_image(
            root_image,
            parts["root"]["device"],
            lambda f: libcalamares.job.setprogress(0.10 + f * 0.60),
        )
        check_erofs_magic(parts["root"]["device"])
        libcalamares.job.setprogress(0.72)

        # ---- 2. mount the target the way the initrd does ------------------------------------
        root_mount_point = tempfile.mkdtemp(prefix="calamares-root-")
        # ro: it is an EROFS. Saying so here rather than relying on the driver refusing writes
        # keeps the failure at mount time instead of at the first write.
        mount(parts["root"]["device"], root_mount_point, "erofs", "ro", mkdir=False)
        mount(parts["var"]["device"], os.path.join(root_mount_point, "var"), "ext4", "defaults")

        # ---- 3. seed /var -------------------------------------------------------------------
        # The var template is the payload profile's own /var, packed by stage 60 from the same
        # staging tree its var.img is built from — so a seeded /var and a dd'd one are the same
        # bytes. It carries the overlay skeleton, /home, /roothome and the preinstalled Flatpak
        # store, which is what lets an install with no network at all produce a machine with its
        # apps already on it.
        if os.path.isfile(var_template):
            debug("unpacking {} into the target /var".format(var_template))
            sh(
                [
                    "tar",
                    "--extract",
                    "--numeric-owner",
                    "--xattrs",
                    "--acls",
                    "--file", var_template,
                    "--directory", os.path.join(root_mount_point, "var"),
                ]
            )
        else:
            # Not fatal: build.conf's INSTALLER_PAYLOAD_FLATPAKS=0 produces a medium with no
            # template at all, and the directories below are all an installed system strictly
            # needs. Say so, so a MISSING template is distinguishable from an omitted one.
            warning("no var template at {} — seeding a bare /var".format(var_template))
        libcalamares.job.setprogress(0.90)

        # Belt and braces: the overlay dirs and the home trees must exist whether they came out
        # of the template or not. /home and /root in the image are symlinks into /var (plan/01),
        # so a missing var/home is a system where the user has no home directory.
        for d in ("overlay/etc/upper", "overlay/etc/work", "home", "roothome"):
            os.makedirs(os.path.join(root_mount_point, "var", d), exist_ok=True)
        os.chmod(os.path.join(root_mount_point, "var", "roothome"), 0o700)

        # ---- 4. THE /etc OVERLAY ------------------------------------------------------------
        # The line this whole installer is built around. lowerdir is the target's own /etc — the
        # pristine vendor copy inside the read-only EROFS — and the overlay is mounted ON TOP OF
        # ITS OWN LOWERDIR, which is legal because lowerdir is resolved before the new mount is
        # grafted. Identical to 90etc-overlay/etc-overlay.sh in the initrd, deliberately: if the
        # two ever disagree, the machine's /etc differs between install time and boot time.
        etc = os.path.join(root_mount_point, "etc")
        mount(
            "overlay",
            etc,
            "overlay",
            "lowerdir={},upperdir={},workdir={}".format(
                etc,
                os.path.join(root_mount_point, "var/overlay/etc/upper"),
                os.path.join(root_mount_point, "var/overlay/etc/work"),
            ),
            mkdir=False,
        )

        # ---- 5. the ESP and the API filesystems ---------------------------------------------
        # /efi, matching config/rootfs/etc/fstab. imagebootloader writes into it next.
        mount(parts["esp"]["device"], os.path.join(root_mount_point, "efi"), "vfat", "umask=0077")

        # What a chroot needs. `users` and `removeuser` run useradd/userdel in here, and shadow's
        # tools want /proc for their own locking; /tmp is a tmpfs because the target's real /tmp
        # is a tmpfs at runtime (fstab) and is a plain read-only directory in the image.
        for src, dst, fstype, opts in (
            ("proc", "proc", "proc", None),
            ("sys", "sys", "sysfs", None),
            ("/dev", "dev", None, "bind"),
            ("tmpfs", "run", "tmpfs", None),
            ("tmpfs", "tmp", "tmpfs", None),
        ):
            mount(src, os.path.join(root_mount_point, dst), fstype, opts)

        libcalamares.globalstorage.insert("rootMountPoint", root_mount_point)
        # The stock modules downstream read these two the way they would after the stock `mount`
        # module ran. extraMounts is what `umount` and `unpackfs` consult; ours is informational,
        # because umount reads /etc/mtab rather than trusting it.
        libcalamares.globalstorage.insert("extraMounts", [])

        os.sync()
        libcalamares.job.setprogress(1.0)
        debug("target mounted at {}".format(root_mount_point))
    except DeployError as e:
        return (e.title, e.message)
    except subprocess.CalledProcessError as e:
        return (
            _("Installation failed"),
            _("The command <pre>{!s}</pre> failed with exit code {!s}.").format(
                " ".join(e.cmd), e.returncode
            ),
        )
    except OSError as e:
        return (_("Installation failed"), str(e))

    return None
