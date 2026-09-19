#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The timezone, written into the installed system (plan/28 §6).
#
# WHAT THIS REPLACES, AND HOW LITTLE OF IT THERE IS. Calamares' `locale` module is a view step
# AND a job, and the job is SetTimezoneJob: it removes the target's /etc/localtime and re-symlinks
# it at the chosen zone. That is the whole of it. When plan/28 replaced the PAGE — because the
# stock one asks a locale question this installer answers on the language page — the job had to
# move with it, and four lines of Python beside four other Python job modules is a better home
# for it than a C++ plugin whose only purpose is to call os.symlink.
#
# AND SINCE plan/29, THE OTHER HALF OF THE SAME QUESTION: whether the installed system keeps its
# clock from the network. The location page asks it with a checkbox, acts on it immediately for
# the machine the installer is running on, and publishes the answer as `locationNetworkTime`;
# this job is what makes that answer true of the machine being installed. Without it the checkbox
# would be a live-session convenience wearing the words "Set the time automatically" — which is a
# sentence about the system you are about to own, not about a USB stick.
#
# /etc/locale.conf IS NOT THIS JOB'S BUSINESS. `imageidentity` writes it, and only for a locale
# the image actually compiled — see its write_locale() and the long note above target_has_locale().
# A second writer here would be the exact failure that note exists to prevent.
#
# THE WRITE LANDS IN AN OVERLAY UPPER, which is why it works at all on an immutable image: /etc
# in the target is an overlay whose upper lives on /var (plan/16 §5.2), so replacing a symlink
# the read-only image ships is a write into the upper and needs no patching of the lower.

import os

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
    return _("Setting the time zone.")


def target_path(root, path):
    return os.path.join(root, path.lstrip("/"))


# systemd-timesyncd is ENABLED in this image's vendor preset
# (config/rootfs/usr/lib/systemd/system-preset/50-distro.preset.in), and build.conf's NTP_SERVERS
# renders a FallbackNTP= drop-in that every profile ships. So "yes" needs nothing done to it: the
# image already is what the checkbox promises, and a job that re-enabled an enabled unit would be
# writing a symlink that is already there to make a log line look busy.
#
# "No" is the case with work in it, and the work is a MASK rather than a disable.
TIMESYNCD_UNIT = "systemd-timesyncd.service"
TIMESYNCD_MASK = "/etc/systemd/system/" + TIMESYNCD_UNIT
# Where `systemctl preset` put the enablement at build time. [Install] says
# WantedBy=sysinit.target, so this is the symlink that actually starts it.
TIMESYNCD_WANT = "/etc/systemd/system/sysinit.target.wants/" + TIMESYNCD_UNIT


def write_network_time(root):
    """Make the installed system agree with the location page's checkbox."""
    # ABSENT IS NOT FALSE. A missing key means the page never ran — the sequence is a
    # configuration file — and the right answer then is the image's own, which is "yes".
    # `if not value` would read an absent key and an explicit False the same way.
    value = libcalamares.globalstorage.value("locationNetworkTime")
    wanted = True if value is None else bool(value)

    mask = target_path(root, TIMESYNCD_MASK)
    want = target_path(root, TIMESYNCD_WANT)

    if wanted:
        # Nothing to do, and the removal below is only for a rerun: Calamares can be restarted
        # against a target this job has already touched, and a mask left from a previous answer
        # would silently outlive the answer that produced it.
        # readlink, not realpath: the question is what this symlink SAYS, and realpath would
        # resolve it against the build host's filesystem rather than the target's.
        if os.path.islink(mask) and os.readlink(mask) == os.devnull:
            os.remove(mask)
            debug("localesetup: removed a stale systemd-timesyncd mask")
        debug("localesetup: the installed system keeps its clock from the network")
        return None

    # A MASK, NOT A DISABLE, and the difference matters on an image whose /etc is an overlay over
    # a read-only lower (plan/16 §5.2). Deleting the .wants symlink is a whiteout in the upper and
    # is undone by the next `systemctl preset-all` — which is a thing an administrator or a later
    # update can legitimately run, and it would quietly switch network time back on. A mask is a
    # statement systemd will not overrule, and `systemctl unmask systemd-timesyncd` is how somebody
    # changes their mind later, in one obvious command.
    #
    # BOTH, though: the whiteout as well, so the installed system does not carry a .wants symlink
    # pointing at a masked unit. That combination works — systemd skips it — but it is the kind of
    # thing that reads as a mistake to the next person looking at the machine.
    try:
        os.makedirs(os.path.dirname(mask), exist_ok=True)
        # lexists, not exists: a symlink to /dev/null is what we are about to write, and exists()
        # follows the link and answers about /dev/null rather than about the link.
        if os.path.lexists(mask):
            os.remove(mask)
        os.symlink(os.devnull, mask)
        if os.path.lexists(want):
            os.remove(want)
    except OSError as e:
        return (
            _("Configuration Error"),
            _("Could not turn off network time on the installed system: {!s}").format(e),
        )

    debug("localesetup: masked {} in the target".format(TIMESYNCD_UNIT))
    return None


def run():
    root = libcalamares.globalstorage.value("rootMountPoint")
    if not root:
        return (
            _("Configuration Error"),
            _("No rootMountPoint is set — <pre>{!s}</pre> did not run.").format("localesetup"),
        )

    region = libcalamares.globalstorage.value("locationRegion")
    zone = libcalamares.globalstorage.value("locationZone")
    if not region or not zone:
        # NOT AN ERROR. The image ships /etc/localtime pointing at UTC, which is a correct
        # answer for a machine nobody told where it is — and the `location` page publishes its
        # default from setConfigurationMap(), so reaching here means the page is not in the
        # sequence at all. That is a configuration decision, not a failure.
        warning(
            "no locationRegion/locationZone in GlobalStorage; leaving the image's "
            "/etc/localtime, which points at UTC"
        )
        # ...and the clock question is still answered. The two halves are independent: a sequence
        # with no location page publishes neither key, but one that publishes only the checkbox —
        # a future page, a preset, a test — should still get the machine it asked for.
        return write_network_time(root)

    # THE ZONE FILE IS CHECKED IN THE TARGET, not on the medium. They carry the same
    # sys-libs/timezone-data today and a symlink into /usr/share/zoneinfo that resolves here and
    # not there would be a dangling /etc/localtime on the installed machine — which glibc reads
    # as UTC, silently, forever.
    relative = os.path.join("/usr/share/zoneinfo", region, zone)
    if not os.path.exists(target_path(root, relative)):
        return (
            _("Configuration Error"),
            _("The installed system has no time zone file for {!s}.").format(
                "{}/{}".format(region, zone)
            ),
        )

    localtime = target_path(root, "/etc/localtime")
    try:
        # REMOVED FIRST, and with os.path.lexists rather than os.path.exists: the image ships
        # /etc/localtime as a SYMLINK, and exists() follows it — so a link pointing at a file the
        # target does not have would read as "not there" and os.symlink would then fail with
        # EEXIST on a path the code had just decided was free.
        if os.path.lexists(localtime):
            os.remove(localtime)
        os.symlink(os.path.join("..", relative.lstrip("/")), localtime)
    except OSError as e:
        return (
            _("Configuration Error"),
            _("Could not write the time zone: {!s}").format(e),
        )

    debug("localesetup: /etc/localtime -> {}".format(relative))

    return write_network_time(root)
