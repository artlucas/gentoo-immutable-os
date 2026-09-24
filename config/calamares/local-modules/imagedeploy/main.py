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
# EROFS image built by the pipeline, and installing it is copying it onto a partition. As of
# plan/34 §7.2/§9 (checkpoint 4) it is not even a staged FILE any more: it is THIS medium's own
# root partition, read straight off the disk this installer is running from.
#
#   1. find this medium's own root device (findmnt -no SOURCE /, cross-checked by PARTLABEL) and
#      copy it into the root_<version> partition, byte for byte, hashing while copying
#   2. mount it read-only, and /var over it
#   3. seed /var from var-base.tar.zst, then copy the LIVE SESSION's own Flatpak store (hard
#      links preserved) — skipped entirely under keep mode
#   4. mount /etc as an overlay whose upper lives on /var, exactly as the initrd does
#   5. mount the ESP and the API filesystems, and hand rootMountPoint to the stock modules
#
# Step 4 is the one that matters. It is the same incantation as
# config/rootfs/usr/lib/dracut/modules.d/90etc-overlay/etc-overlay.sh, including mounting the
# overlay onto its own lowerdir — and with it in place, every job downstream (localesetup,
# keyboardsetup, accountsetup) writes to /etc/... exactly as a stock module would on a mutable
# distro, and the writes land in the upper on /var because that is what the mount does. No
# patched modules anywhere in this installer (plan/16 §5.2). accountsetup no longer removes a
# live user from the TARGET here — plan/34 §5 moved that account off the root image entirely,
# so there is nothing on an installed disk's lower /etc for a removeuser-style job to find; this
# module's own check_no_live_leakage() is what proves the upper carries none either.

import json
import os
import subprocess
import tempfile

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

    BY LABEL AND MOUNT POINT, never by index. The partitioner reports every partition on every
    touched device in on-disk order, and an index would silently follow whatever the layout in
    scripts/lib/layout.sh happens to be today. (Before plan/24 the partitioner was Calamares'
    stock `partition` module and the layout was a YAML block; neither line below changed when
    `disksetup` replaced it, which is the test of whether the replacement was honest.)

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


def find_live_root_source():
    """The device backing THIS medium's own `/` — not /usr.

    The systemd-sysext extension merges only /usr; `/` itself is unaffected by that overlay and
    is still, exactly as always, whatever device the medium's UKI cmdline named at
    root=PARTLABEL=.... findmnt reports the RESOLVED device, which is what a raw open() needs.
    """
    out = sh(["findmnt", "-no", "SOURCE", "/"], capture_output=True, text=True)
    device = out.stdout.strip()
    if not device:
        raise DeployError(
            _("Internal error"),
            _("findmnt could not resolve this medium's own root device."),
        )
    return device


def partlabel_of(device):
    out = sh(["lsblk", "-no", "PARTLABEL", device], capture_output=True, text=True)
    return out.stdout.strip()


def write_and_verify(source_device, dest_device, expected_size, expected_sha256, progress):
    """Copy exactly `expected_size` bytes from the medium's own root device to the target
    partition, hashing while copying, and fail if either the byte count or the hash disagrees
    with the manifest.

    ONE READ of the source, not a separate verify pass then a write: the old design (plan/16)
    sha256'd a staged payload FILE before writing it, which meant reading the medium twice —
    the whole point of hashing while copying is that the medium (now the live root device
    itself, not a file under it) is read once, which matters more on a USB stick than it did on
    a staged file. A Python loop rather than `dd`: dd reports progress only to a tty, and the
    thing a user stares at for a minute or two should have a moving bar. os.fsync at the end
    (not just close) because the next thing that happens is a mount of this very device.
    """
    import hashlib

    debug("copying {} bytes from {} to {}, hashing while copying".format(
        expected_size, source_device, dest_device))
    h = hashlib.sha256()
    written = 0
    with open(source_device, "rb") as src, open(dest_device, "r+b") as dst:
        while written < expected_size:
            chunk = src.read(min(CHUNK, expected_size - written))
            if not chunk:
                break
            dst.write(chunk)
            h.update(chunk)
            written += len(chunk)
            progress(written / expected_size)
        dst.flush()
        os.fsync(dst.fileno())

    if written != expected_size:
        raise DeployError(
            _("Installation failed"),
            _(
                "Only {!s} of {!s} expected bytes were read from this medium's own root "
                "device — the install medium may be damaged."
            ).format(written, expected_size),
        )
    actual = h.hexdigest()
    if actual != expected_sha256:
        raise DeployError(
            _("Installation failed"),
            _(
                "The system image read from this medium does not match its own manifest: "
                "got {!s}, expected {!s}. The install medium may be damaged; write it again."
            ).format(actual[:16], expected_sha256[:16]),
        )
    return written


def check_no_live_leakage(root_mount_point, live_user):
    """The installed disk's /var must carry none of THIS build's own live-medium state.

    Three specific things, because they are the three places live-only state lives (plan/34
    §2, §5): the sysext itself (nothing merges it on an installed system — there is no
    /var/lib/extensions/immos-installer to merge), the live user's home, and the live user's
    entry in the /etc overlay's own upper passwd. var-base.tar.zst (§7.1) already excludes all
    three by construction; this re-proves it against what is ACTUALLY on the target disk after
    the copy, the same "trust the built artifact, not the recipe" principle stage 60's own
    checks use.
    """
    var = os.path.join(root_mount_point, "var")
    bad = []
    if os.path.isdir(os.path.join(var, "lib", "extensions", "immos-installer")):
        bad.append("var/lib/extensions/immos-installer")
    if os.path.lexists(os.path.join(var, "home", live_user)):
        bad.append("var/home/{}".format(live_user))
    upper_passwd = os.path.join(var, "overlay", "etc", "upper", "passwd")
    if os.path.isfile(upper_passwd):
        with open(upper_passwd, encoding="utf-8", errors="replace") as f:
            if any(
                line.split(":", 1)[0] == live_user
                for line in f
                if line.strip() and not line.startswith("#")
            ):
                bad.append("var/overlay/etc/upper/passwd names {}".format(live_user))
    if bad:
        raise DeployError(
            _("Installation failed"),
            _(
                "The installed system's /var still carries live-medium state that must "
                "never reach an installed disk: {!s}."
            ).format(", ".join(bad)),
        )


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
    # Read once, at the top, and used at the two places below that differ for a kept disk
    # (plan/33 §7): everything else in this module — writing the root image, mounting it, the
    # /etc overlay, the ESP, the API filesystems — is identical whichever way this reads, because
    # disksetup already made the two paths converge on the same `partitions` contract.
    keep = bool(libcalamares.globalstorage.value("diskKeepData"))
    payload_dir = conf.get("payloadDir", "/var/lib/install")
    root_label = conf.get("rootPartLabel")
    if not root_label:
        return (
            _("Configuration Error"),
            _("<pre>{!s}</pre> does not name rootPartLabel.").format("imagedeploy"),
        )
    live_root_label = conf.get("liveRootPartLabel")
    live_user = conf.get("liveUser")
    if not live_root_label or not live_user:
        return (
            _("Configuration Error"),
            _("<pre>{!s}</pre> does not name liveRootPartLabel and liveUser.").format(
                "imagedeploy"
            ),
        )

    var_base = os.path.join(payload_dir, conf.get("varBase", "var-base.tar.zst"))
    manifest_path = os.path.join(payload_dir, conf.get("manifest", "manifest.json"))

    try:
        parts = find_partitions(root_label)

        # ---- 0. the payload that IS still a file, and the manifest describing the one that
        # is not (plan/34 §7.1/§7.2) ------------------------------------------------------------
        for label, path in (("/var seed", var_base), ("manifest", manifest_path)):
            if not os.path.isfile(path):
                raise DeployError(
                    _("Installation failed"),
                    _("The {!s} is missing from the install medium ({!s}).").format(label, path),
                )
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
        root_erofs_meta = manifest.get("root_erofs", {})
        expected_size = root_erofs_meta.get("size")
        expected_sha256 = root_erofs_meta.get("sha256")
        if not expected_size or not expected_sha256:
            raise DeployError(
                _("Installation failed"),
                _("The manifest names no root_erofs size and sha256 to install from."),
            )

        # ---- 1. the root filesystem, byte for byte, straight off this medium's own disk ------
        # This is the install. Everything after it is mounting and identity.
        #
        # settle first. The partition module has just rewritten the GPT and run mkfs, and the
        # /dev nodes for the new partitions are created by udev in response — asynchronously. A
        # classic installer race is to open a device node that does not exist yet, or worse, one
        # that still refers to the PREVIOUS table's partition. Cheap insurance, and it is the
        # kind of failure that only appears on someone else's disk.
        try:
            sh(["udevadm", "settle", "--timeout=30"])
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            warning("udevadm settle failed ({}); continuing".format(e))
        for name, part in parts.items():
            if not os.path.exists(part["device"]):
                raise DeployError(
                    _("Installation failed"),
                    _("The {!s} partition {!s} did not appear after partitioning.").format(
                        name, part["device"]
                    ),
                )

        # The medium's OWN root device, cross-checked against its own PARTLABEL before it is
        # trusted as the install source — plan/34 §2's whole guarantee ("a machine installed
        # from this medium is indistinguishable from one dd'd from the desktop image") depends
        # on this actually being that byte-for-byte artifact, not merely "whatever / happens to
        # be mounted from" on a machine running an unexpected kernel command line.
        live_root_device = find_live_root_source()
        live_root_actual_label = partlabel_of(live_root_device)
        if live_root_actual_label != live_root_label:
            raise DeployError(
                _("Internal error"),
                _(
                    "This medium's own root device ({!s}) is labelled '{!s}', expected '{!s}' "
                    "— refusing to install from a device that is not what this build's own "
                    "UKI says it booted."
                ).format(live_root_device, live_root_actual_label, live_root_label),
            )

        write_and_verify(
            live_root_device,
            parts["root"]["device"],
            expected_size,
            expected_sha256,
            lambda f: libcalamares.job.setprogress(f * 0.70),
        )
        check_erofs_magic(parts["root"]["device"])
        libcalamares.job.setprogress(0.72)

        # ---- 2. mount the target the way the initrd does ------------------------------------
        root_mount_point = tempfile.mkdtemp(prefix="calamares-root-")
        # ro: it is an EROFS. Saying so here rather than relying on the driver refusing writes
        # keeps the failure at mount time instead of at the first write.
        mount(parts["root"]["device"], root_mount_point, "erofs", "ro", mkdir=False)
        mount(parts["var"]["device"], os.path.join(root_mount_point, "var"), "ext4", "defaults")

        # ---- 3. seed /var, then copy the LIVE SESSION's own Flatpak store (plan/34 §7.1/§9) ---
        # var-base.tar.zst is the payload profile's own /var minus lib/flatpak — packed by
        # stage 40 from the same var.tar.zst stage 60's var.img is built from, so a seeded /var
        # and a dd'd one agree on everything except the store. It carries the overlay skeleton,
        # /home, /roothome and lib/immos/flatpak-preinstall.done, which is what lets an install
        # with no network at all produce a machine whose firstboot unit stays quiet.
        if keep:
            # KEEPING (plan/33 §7): the var partition already has an overlay skeleton, homes and
            # a Flatpak store of its own — they are the entire reason var was kept rather than
            # erased. Extracting the seed over them, or overwriting the store, would replace the
            # accounts, files and apps this feature exists to keep with the image's own factory
            # defaults.
            debug("imagedeploy: keeping — not reseeding /var or the Flatpak store over the kept one")
        else:
            if os.path.isfile(var_base):
                debug("unpacking {} into the target /var".format(var_base))
                sh(
                    [
                        "tar",
                        "--extract",
                        # Explicit rather than relying on tar's magic sniffing: the failure mode
                        # of a missed detection is tar reading compressed bytes as a tar stream
                        # and reporting a corrupt archive, which reads as a corrupt PAYLOAD.
                        "--zstd",
                        "--numeric-owner",
                        "--xattrs",
                        "--acls",
                        "--file", var_base,
                        "--directory", os.path.join(root_mount_point, "var"),
                    ]
                )
            else:
                # Not fatal: the skeleton directories below are all an installed system strictly
                # needs. Say so, so a MISSING seed is distinguishable from an omitted one.
                warning("no /var seed at {} — seeding a bare /var".format(var_base))
            libcalamares.job.setprogress(0.85)

            # The Flatpak store: copied from THIS LIVE SESSION's own /var/lib/flatpak, not
            # unpacked from any payload file — plan/34 §7.1 unpacks it into the medium's own
            # /var once, at build time, and it is from there (as possibly modified by whatever
            # the person running this installer did in Discover before clicking Install) that
            # an install's store comes. This is intended, not a bug: a Flatpak added during the
            # live session carries over to the installed machine (plan/34 §9), the same as any
            # other live-session write to /var would.
            #
            # cp -a, not tar or rsync -a: Flatpak's OSTree-backed store relies on hard links
            # between repo objects for its own deduplication, and cp -a (unlike a plain cp -r
            # or rsync without -H) detects and recreates hard links among the files it copies
            # together in one invocation.
            live_flatpak = "/var/lib/flatpak"
            if os.path.isdir(live_flatpak):
                dest_flatpak = os.path.join(root_mount_point, "var", "lib", "flatpak")
                os.makedirs(os.path.dirname(dest_flatpak), exist_ok=True)
                debug("copying the live session's own Flatpak store to the target (hard links preserved)")
                sh(["cp", "-a", "--", live_flatpak, dest_flatpak])
            else:
                warning("no Flatpak store at {} in the live session".format(live_flatpak))
            libcalamares.job.setprogress(0.90)

        # Belt and braces: the overlay dirs and the home trees must exist whether they came out
        # of the seed or not. /home and /root in the image are symlinks into /var (plan/01), so
        # a missing var/home is a system where the user has no home directory.
        for d in ("overlay/etc/upper", "overlay/etc/work", "home", "roothome"):
            os.makedirs(os.path.join(root_mount_point, "var", d), exist_ok=True)
        os.chmod(os.path.join(root_mount_point, "var", "roothome"), 0o700)

        # ---- 3b. post-condition: none of THIS build's own live-medium state reached the disk -
        check_no_live_leakage(root_mount_point, live_user)

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

        # ---- 4b. the hostname, EARLY, and this is not where it belongs ----------------------
        # It is here because of an ordering fact in Calamares' users module that has no other
        # answer available to us. Config::createJobs appends ActiveDirectoryJob at :1088 and
        # SetHostNameJob at :1109 — so a domain join runs BEFORE the hostname is written. At that
        # moment the target's /etc/hostname is still the image's, and this live medium's own
        # hostname is "<id>-<machine-id prefix>" from <id>-hostname-init.service. The computer
        # account would be created in Active Directory under that name, silently, and the machine
        # would answer to a different one for the rest of its life (plan/18 §7.3).
        #
        # Config::setHostName publishes the user's choice to GlobalStorage as they type it on the
        # page (Config.cpp:278), and this module runs in the exec phase, after every page. So the
        # value is available here, an hour of wall-clock before the job that needs it.
        # SetHostNameJob writes the same string again later, which makes this a harmless
        # duplicate rather than a conflict.
        #
        # Written after the overlay mount above, so it lands in the upper on /var like every
        # other identity file — not into the read-only lower, where it could not go anyway.
        #
        # SKIPPED WHILE KEEPING (plan/33 §7): the kept system's own /etc/hostname is exactly
        # what plan/33 §1 promises to leave alone, and the race this early write exists to avoid
        # cannot happen on this path anyway — accountsetup stands down entirely under keep, so
        # no domain join is being started fresh here for a hostname to race.
        if keep:
            debug("imagedeploy: keeping — not writing /etc/hostname over the kept system's own")
        else:
            hostname = libcalamares.globalstorage.value("hostname")
            if hostname:
                with open(os.path.join(etc, "hostname"), "w") as f:
                    f.write(hostname + "\n")
                debug("wrote /etc/hostname early for the AD join: {}".format(hostname))
            else:
                warning("no hostname in global storage; an AD join would name the computer "
                        "account after the live medium")

        # ---- 5. the ESP and the API filesystems ---------------------------------------------
        # /efi. Nothing in the target's own /etc/fstab names this any more (plan/34 §4) — the
        # desktop UKI's cmdline mounts it by PARTLABEL at boot — but the install still needs it
        # mounted here for imagebootloader, which writes into it next.
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
