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
#   1. AUTOLOGIN, ONLY WHEN ASKED FOR. The live medium autologins, and it has to: that is how it
#      reaches a Plasma session to run this installer from. But that autologin's own
#      /etc/plasmalogin.conf.d/10-autologin.conf is not in the read-only root at all any more —
#      plan/34 §5 moved it out of config/rootfs into config/live-seed, which stage 40 renders
#      straight into THIS BUILD'S OWN live medium's /etc overlay upper, never into the lower
#      EROFS both profiles ship. var-base.tar.zst (what imagedeploy seeds the target's /var from)
#      is the desktop build's var, which never renders that live-only template either. So an
#      installed system's /etc starts with no autologin config of any kind, and there is nothing
#      here for this job to override. Since plan/26 §4 the accounts page can ask for autologin on
#      the installed machine too — when GlobalStorage says autoLogin and names the created user,
#      this job writes the one file that turns it on. When it was not asked for, it writes
#      nothing, because nothing needs overriding.
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


def write_autologin_dropin(root, conf, username):
    """Write the autologin drop-in — but ONLY when the accounts page asked for it (plan/26 §4).

    There is no "otherwise" branch any more. Post-plan/34 §5, 10-autologin.conf never ships in
    the read-only root and var-base.tar.zst (the desktop build's own var) never renders it
    either — see the module docstring above. An installed system's /etc simply has no autologin
    config until this job writes one, so the not-requested case needs no file: the login screen
    is already what a normal install without this job's help would produce.

    A drop-in, not an edit. And the MTIME matters here in a way nothing about the file's content
    reveals: Plasma Login Manager only re-reads plasmalogin.conf.d when its newest mtime beats a
    zero-initialised "already loaded" stamp — the bug that cost 0.3.0 its autologin, and that
    stage 60 now stamps SOURCE_DATE_EPOCH to avoid. A file written here carries a real current
    mtime, decades after the image's, so the directory is re-read and this file is seen. That is
    the right outcome by luck rather than by design, so it is written down.

    The keys mirror 10-autologin.conf.in key for key — User, Session, Relogin — so an installed
    machine that logs itself in is the live medium's arrangement with one name swapped, not an
    improvisation.
    """
    if not username:
        debug("autologin was not requested; the target's /etc has no autologin config to begin "
              "with, so there is nothing to write")
        return
    path = target_path(root, conf.get("autologinDropIn", "/etc/plasmalogin.conf.d/20-autologin.conf"))
    if not os.path.isdir(os.path.dirname(path)):
        # No Plasma Login Manager in this payload (a console profile, say). Nothing to turn on.
        debug("no plasmalogin.conf.d in the target; skipping the autologin drop-in")
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            "# Written by the installer at the request the accounts page recorded: this\n"
            "# machine logs straight in as the created user. Nothing else in the target's /etc\n"
            "# ships an autologin config (plan/34 §5) — this file is the only one. Delete it to\n"
            "# put the login screen back.\n"
            "[Autologin]\n"
            "User={}\n"
            "Session=plasma\n"
            "Relogin=false\n".format(username)
        )
    os.chmod(path, 0o644)
    debug("autologin enabled for {} via {}".format(username, path))


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

    if bool(libcalamares.globalstorage.value("diskKeepData")):
        # KEEPING (plan/33 §8), and this is not a nicety the way it is for localesetup and
        # keyboardsetup: the machine-id guard further down truncates the overlay upper's
        # machine-id whenever /etc/machine-id is non-empty, on the assumption that a non-empty
        # one only ever got there by mistake (plan/01 — the image ships it EMPTY). A KEPT var
        # already carries the real machine-id from the disk's very first boot, and running that
        # guard unmodified would truncate it back to nothing on every reinstall — the one piece
        # of per-machine identity this whole feature is supposed to leave alone.
        debug("imageidentity: keeping — hostname, subuids, locale and machine-id are the kept system's own")
        return None

    username = libcalamares.globalstorage.value("username")

    try:
        # The accounts page's checkbox (plan/26 §4): true only in local mode. A request with no
        # username behind it cannot be honoured — and would only arise from a hand-edited
        # GlobalStorage — so it warns and writes the disable drop-in rather than a User= that
        # names nobody.
        autologin = bool(libcalamares.globalstorage.value("autoLogin"))
        if autologin and not username:
            warning(
                "autoLogin is set but no username is in GlobalStorage; "
                "leaving the target's /etc with no autologin config"
            )
        write_autologin_dropin(root, conf, autologin and username)
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
