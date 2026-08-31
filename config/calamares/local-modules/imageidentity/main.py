#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# imageidentity — the four things no stock Calamares module covers on this distro.
#
# Runs last, after `users` has created the real account and `removeuser` has deleted the live
# one. Everything it writes goes into the target's /etc, which imagedeploy mounted as an overlay
# whose upper lives on /var — so each write is a copy-up that shadows the read-only image's own
# copy (plan/16 §5.2, §5.4).
#
#   1. AUTOLOGIN OFF. The live medium autologins, and it has to: that is how it reaches a Plasma
#      session to run this installer from. That autologin lives in the image's
#      /etc/plasmalogin.conf.d/10-autologin.conf, inside the read-only EROFS the installed system
#      also uses, so it cannot be deleted — deleting a lower file through an overlay needs a
#      whiteout device, which is not something to leave on a user's disk. Drop-ins sort
#      lexically, so a 20- file in the upper wins.
#
#   2. SUBUID/SUBGID. Rootless podman needs subordinate ID ranges; stage 40 allocates them for
#      the live user and Calamares' `users` module has no concept of them (plan/13, plan/16 §5.4).
#      Without these, every `podman` and `distrobox` call fails at first use with "cannot find
#      UID/GID for user" — months after the install, with nothing to connect it to.
#
#   3. THE HOSTNAME STAMP. The image ships a first-boot unit that sets <id>-<machine-id prefix>
#      unless a stamp file exists. Left alone it runs on the installed system's first boot and
#      overwrites the hostname the user typed on the users page.
#
#   4. /etc/locale.conf, but only for a locale the image can actually load. See write_locale().

import os
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


def pretty_name():
    return _("Configuring the installed system.")


def target_path(root, path):
    return os.path.join(root, path.lstrip("/"))


def write_autologin_dropin(root, conf):
    """Turn the live medium's autologin off on the installed system.

    A drop-in, not an edit. And the MTIME matters here in a way nothing about the file's content
    reveals: Plasma Login Manager only re-reads plasmalogin.conf.d when its newest mtime beats a
    zero-initialised "already loaded" stamp — the bug that cost 0.3.0 its autologin, and that
    stage 60 now stamps SOURCE_DATE_EPOCH to avoid. A file written here carries a real current
    mtime, decades after the image's, so the directory is re-read and this file is seen. That is
    the right outcome by luck rather than by design, so it is written down.
    """
    path = target_path(root, conf.get("autologinDropIn", "/etc/plasmalogin.conf.d/20-no-autologin.conf"))
    if not os.path.isdir(os.path.dirname(path)):
        # No Plasma Login Manager in this payload (a console profile, say). Nothing to turn off.
        debug("no plasmalogin.conf.d in the target; skipping the autologin drop-in")
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            "# Written by the installer. Overrides 10-autologin.conf, which ships inside the\n"
            "# read-only system image and cannot be deleted from it — drop-ins sort lexically,\n"
            "# so this later file wins.\n"
            "#\n"
            "# An empty User is what actually disables autologin: Plasma Login Manager's\n"
            "# autologin branch is never entered for an empty username. Delete this file to\n"
            "# restore the image's autologin.\n"
            "[Autologin]\n"
            "User=\n"
            "Session=\n"
        )
    os.chmod(path, 0o644)
    debug("autologin disabled via {}".format(path))


def write_subids(root, username, conf):
    """Allocate subordinate UID/GID ranges for the created user.

    Written directly rather than through `usermod --add-subuids` in a chroot, because the files
    are two columns of text and doing it here means one failure mode instead of two. The range
    matches what stage 40 gives the live user: 100000-165535, the default login.defs window.
    """
    start = int(conf.get("subidStart", 100000))
    count = int(conf.get("subidCount", 65536))
    for name in ("subuid", "subgid"):
        path = target_path(root, "/etc/" + name)
        existing = []
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                existing = f.read().splitlines()
        if any(line.startswith(username + ":") for line in existing):
            debug("{} already has a range in /etc/{}".format(username, name))
            continue
        # Never reuse a range another account already holds. The live user's entry is still in
        # the lower's copy of this file at this point unless removeuser rewrote it, and two
        # accounts mapping the same subordinate range is a container isolation hole.
        taken = set()
        for line in existing:
            parts = line.split(":")
            if len(parts) == 3 and parts[1].isdigit():
                taken.add(int(parts[1]))
        base = start
        while base in taken:
            base += count
        with open(path, "a", encoding="utf-8") as f:
            if existing and not existing[-1].endswith("\n"):
                f.write("\n")
            f.write("{}:{}:{}\n".format(username, base, count))
        os.chmod(path, 0o644)
        debug("allocated /etc/{} range {}:{} for {}".format(name, base, count, username))


def stamp_hostname(root, conf):
    """Stop the image's first-boot hostname unit from overwriting the user's choice.

    <id>-hostname-init.service has ConditionPathExists=!/var/lib/<id>/hostname-init.done and
    would otherwise run on the installed system's first boot and set <id>-<machine-id prefix>.
    The stamp goes on /var, which is where the unit itself writes it.
    """
    stamp = conf.get("hostnameStamp")
    if not stamp:
        return
    if not libcalamares.globalstorage.value("hostname"):
        debug("no hostname was set by the installer; leaving the first-boot unit to run")
        return
    path = target_path(root, stamp)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("set by the installer\n")
    debug("hostname stamp written to {}".format(path))


def target_has_locale(root, locale_name):
    """Can the installed system actually load this locale?

    THE LIMITATION THIS GUARDS, stated plainly: the image compiles only the locales named in
    build.conf's LOCALE_GEN — by default just en_US.UTF-8 — into /usr/lib/locale/locale-archive,
    which lives in the READ-ONLY root. Nothing on the installed system can add to it. So writing
    LANG=de_DE.UTF-8 into /etc/locale.conf for a locale that is not in the archive does not give
    the user German; it gives them the C locale, which is worse than the en_US they had.
    LOCALES_KEEP (message catalogs, i.e. the translated UI) is a different and much longer list,
    which is why picking German here mostly works and the formats stay American.
    """
    try:
        out = subprocess.run(
            ["chroot", root, "locale", "-a"],
            check=True, capture_output=True, text=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError, OSError) as e:
        warning("could not list the target's locales ({}); leaving /etc/locale.conf alone".format(e))
        return False
    wanted = locale_name.replace("UTF-8", "utf8").replace("-", "").lower()
    return any(line.strip().replace("-", "").lower() == wanted for line in out.splitlines())


def write_locale(root):
    locale_conf = libcalamares.globalstorage.value("localeConf")
    if not locale_conf:
        debug("no localeConf in GlobalStorage; leaving the image's /etc/locale.conf")
        return
    lang = locale_conf.get("LANG")
    if not lang:
        return
    if not target_has_locale(root, lang):
        warning(
            "the target has no compiled locale for {} — keeping the image's default. "
            "Add it to LOCALE_GEN in config/build.conf to offer it.".format(lang)
        )
        return
    path = target_path(root, "/etc/locale.conf")
    with open(path, "w", encoding="utf-8") as f:
        for key in sorted(locale_conf):
            value = locale_conf[key]
            if value:
                f.write("{}={}\n".format(key, value))
    os.chmod(path, 0o644)
    debug("wrote {} ({})".format(path, lang))


def run():
    conf = libcalamares.job.configuration
    root = libcalamares.globalstorage.value("rootMountPoint")
    if not root:
        return (
            _("Configuration Error"),
            _("No rootMountPoint is set — <pre>{!s}</pre> did not run.").format("imagedeploy"),
        )
    username = libcalamares.globalstorage.value("username")

    try:
        write_autologin_dropin(root, conf)
        if username:
            write_subids(root, username, conf)
        else:
            warning("no username in GlobalStorage; skipping subuid/subgid allocation")
        stamp_hostname(root, conf)
        write_locale(root)

        # The machine-id must stay EMPTY on the installed system. The image ships an empty
        # /etc/machine-id inside the read-only root so systemd generates a fresh one per machine
        # on first boot and commits it to the overlay upper (plan/01). If anything in this
        # sequence caused one to be written into the upper, every machine installed from this
        # medium would share it — and machine-id is what systemd keys per-machine state on, so
        # the symptom would be subtle and remote.
        machine_id = target_path(root, "/etc/machine-id")
        if os.path.isfile(machine_id) and os.path.getsize(machine_id) > 0:
            upper = os.path.join(root, "var/overlay/etc/upper/machine-id")
            if os.path.exists(upper):
                warning("a machine-id was written into the target's overlay; clearing it")
                os.truncate(upper, 0)

        os.sync()
    except OSError as e:
        return (_("Installation failed"), str(e))

    return None
