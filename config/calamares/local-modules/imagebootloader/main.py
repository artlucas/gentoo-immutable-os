#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# imagebootloader — put systemd-boot and the UKI on the target's ESP.
#
# Replaces Calamares' `bootloader` and `grubcfg` (plan/16 §5.3, "Drop"), which is a generous
# reading of "drop": there is no bootloader to install in the sense those modules mean. This
# distro boots a Unified Kernel Image — kernel, initrd, cmdline and os-release in one signed-
# shaped PE binary, built by stage 40 — through systemd-boot. So the entire boot configuration
# is four file copies and a three-line loader.conf, and nothing here generates anything.
#
# THE FILES COME FROM THE PAYLOAD, NOT FROM THE LIVE SYSTEM. systemd-bootx64.efi is read out of
# the mounted target's own /usr/lib/systemd/boot/efi/, so the EFI binary on the installed ESP is
# the one that belongs to the systemd the installed system runs. The live medium happens to
# carry the same version today — both profiles resolve from one config root and one lock — but
# "happens to" is exactly the kind of assumption that stops being true the first time the two
# profiles are relocked apart.
#
# This mirrors section 3 of scripts/stages/60-image.sh, which builds the factory image's ESP.
# The two produce the same ESP contents, which is what makes an installed machine
# indistinguishable from one dd'd from the .img (plan/16 §3.4).

import os
import shutil
import subprocess

import libcalamares

# See the note in imagedeploy/main.py: this is the idiom every stock module uses.
debug = libcalamares.utils.debug
warning = libcalamares.utils.warning

import gettext

_ = gettext.translation(
    "calamares-python",
    localedir=libcalamares.utils.gettext_path(),
    languages=libcalamares.utils.gettext_languages(),
    fallback=True,
).gettext

SDBOOT = "usr/lib/systemd/boot/efi/systemd-bootx64.efi"


def pretty_name():
    return _("Installing the boot loader.")


def run():
    conf = libcalamares.job.configuration
    root_mount_point = libcalamares.globalstorage.value("rootMountPoint")
    if not root_mount_point:
        return (
            _("Configuration Error"),
            _("No rootMountPoint is set — <pre>{!s}</pre> did not run.").format("imagedeploy"),
        )

    payload_dir = conf.get("payloadDir", "/var/lib/install")
    uki_source = os.path.join(payload_dir, conf.get("uki", "uki.efi"))
    uki_name = conf.get("ukiName")
    distro_id = conf.get("distroId", "")
    esp = os.path.join(root_mount_point, conf.get("espMountPoint", "efi").lstrip("/"))

    if not uki_name:
        return (
            _("Configuration Error"),
            _("<pre>{!s}</pre> does not name ukiName.").format("imagebootloader"),
        )

    sdboot = os.path.join(root_mount_point, SDBOOT)
    for label, path in ((_("boot loader"), sdboot), (_("kernel image"), uki_source)):
        if not os.path.isfile(path):
            return (
                _("Installation failed"),
                _("The {!s} is missing ({!s}).").format(label, path),
            )

    try:
        for d in ("EFI/BOOT", "EFI/systemd", "EFI/Linux", "loader"):
            os.makedirs(os.path.join(esp, d), exist_ok=True)

        # BOOTX64.EFI is the removable-media fallback path, which is what makes the disk bootable
        # on firmware that has no NVRAM entry for it — including every machine where the entry
        # below could not be written. EFI/systemd/ is where systemd-boot expects to find itself
        # for its own update path (bootctl update).
        shutil.copy2(sdboot, os.path.join(esp, "EFI/BOOT/BOOTX64.EFI"))
        shutil.copy2(sdboot, os.path.join(esp, "EFI/systemd/systemd-bootx64.efi"))

        # Byte-identical to the loader.conf stage 60 writes.
        #   timeout 0   boot straight through; the menu is still reachable by holding a key
        #   default     the UKI glob, so a sysupdate-installed newer version wins on name order
        #   editor no   no cmdline editing at the boot menu — the cmdline is inside the signed-
        #               shaped UKI and editing it is a root shell for anyone at the keyboard
        with open(os.path.join(esp, "loader/loader.conf"), "w", encoding="utf-8") as f:
            f.write("timeout 0\ndefault {}_*\neditor no\n".format(distro_id))

        # The factory UKI ships WITHOUT a tries counter: it is the known-good baseline that
        # Automatic Boot Assessment falls back TO, so it must never be counted down (plan/01).
        # Only sysupdate-installed UKIs carry +3-0 suffixes.
        uki_target = os.path.join(esp, "EFI/Linux", uki_name)
        shutil.copy2(uki_source, uki_target)
        os.chmod(uki_target, 0o444)

        os.sync()
        debug("ESP populated at {}".format(esp))
    except OSError as e:
        return (_("Installation failed"), str(e))

    # ---- the NVRAM entry, best-effort ------------------------------------------------------
    # Deliberately NOT fatal. The disk is already bootable through EFI/BOOT/BOOTX64.EFI above,
    # so a machine that cannot take the entry still boots — and the cases where it cannot are
    # real and common: a VM with no persistent efivars, firmware with a full or read-only
    # variable store, or an install running from a medium booted in a mode where
    # /sys/firmware/efi/efivars is not writable. Failing the whole install over an optimisation
    # would be wrong. Warn, and let the fallback path do its job.
    if conf.get("efiBootEntry", True):
        device, part = esp_device(root_mount_point)
        if device and part:
            label = conf.get("efiBootEntryLabel") or distro_id
            cmd = [
                "efibootmgr", "--create", "--quiet",
                "--disk", device, "--part", str(part),
                "--label", label,
                "--loader", "\\EFI\\BOOT\\BOOTX64.EFI",
            ]
            try:
                debug("running: {}".format(" ".join(cmd)))
                subprocess.run(cmd, check=True, capture_output=True)
            except (subprocess.CalledProcessError, FileNotFoundError) as e:
                warning(
                    "could not create an EFI boot entry ({}); the disk is still bootable "
                    "through the removable-media path".format(e)
                )
        else:
            warning("could not identify the ESP's disk; skipping the EFI boot entry")

    return None


def esp_device(root_mount_point):
    """Split the ESP's /dev/... node into (disk, partition number) for efibootmgr.

    Read out of GlobalStorage rather than parsed off the mount, and split with the same rule
    Calamares' own mount module uses for the inverse problem: nvme0n1p1 and mmcblk0p1 put a 'p'
    between the disk and the partition number, sda1 does not.
    """
    import re

    for p in libcalamares.globalstorage.value("partitions") or []:
        if p.get("mountPoint") != "/efi":
            continue
        node = p.get("device", "")
        m = re.match(r"^(/dev/(?:nvme\d+n\d+|mmcblk\d+|loop\d+))p(\d+)$", node)
        if m:
            return m.group(1), int(m.group(2))
        m = re.match(r"^(/dev/[a-z]+)(\d+)$", node)
        if m:
            return m.group(1), int(m.group(2))
        warning("unrecognised ESP device node: {}".format(node))
    del root_mount_point
    return None, None
