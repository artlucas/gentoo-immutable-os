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
        return None

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
    return None
