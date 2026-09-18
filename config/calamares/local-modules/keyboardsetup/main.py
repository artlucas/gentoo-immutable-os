#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The keyboard layout, written into the installed system (plan/28 §6).
#
# WHAT THIS REPLACES. Calamares' `keyboard` module is a view step AND a job, and the job is
# SetKeyboardLayoutJob: it writes /etc/vconsole.conf (KEYMAP=) and
# /etc/X11/xorg.conf.d/00-keyboard.conf in the target. plan/28 replaced the page, so the job moved
# with it — to Python, beside the five other job modules this installer already has.
#
# THE MAP IS THE TARGET'S OWN, AND THAT IS THE ONE REAL IMPROVEMENT HERE. Upstream resolves an
# X11 layout to a console keymap through a kbd-model-map compiled into Calamares' QRC — a copy of
# a table, frozen at whatever release built the binary. systemd SHIPS that table, at
# /usr/share/systemd/kbd-model-map, and it is the same file systemd-localed consults on the
# installed machine. Reading the target's copy means the answer this job writes and the answer
# localed would give cannot disagree, and this repo ships no table at all.
#
# BOTH WRITES LAND IN AN OVERLAY UPPER (plan/16 §5.2): /etc in the target is an overlay whose
# upper lives on /var, so these replace the image's files without patching the read-only lower.
#
# xorg.conf.d ON A WAYLAND-ONLY IMAGE is not the dead end it looks like, and the reasoning is
# config/calamares/modules/keyboard.conf's, kept: systemd-localed reads and writes exactly that
# file as the system's X11 keyboard configuration, and kwin_wayland started with --locale1 takes
# its layout from localed. That is the path this image is on.

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

MODEL_MAP = "/usr/share/systemd/kbd-model-map"
CONSOLE_KEYMAPS = "/usr/share/keymaps"
XKB_MODEL = "pc105"


def pretty_name():
    return _("Setting the keyboard layout.")


def target_path(root, path):
    return os.path.join(root, path.lstrip("/"))


def console_keymap(root, layout, variant):
    """The console keymap for an X11 layout/variant, out of the TARGET's kbd-model-map.

    The file's columns are: consolelayout, xlayout, xmodel, xvariant, xoptions — whitespace
    separated, with "-" standing in for "no variant". An xlayout column can name SEVERAL layouts
    ("mk,us"), which is how a row describes a keymap that includes a Latin fallback; the FIRST of
    them is the one the row is really about, and that is what is matched here.

    An exact variant match wins over a row with no variant, because "de" and "de nodeadkeys" are
    different keyboards and the file lists both. A layout with neither is not an error — it means
    this keyboard has no console equivalent, and KEYMAP stays as the image shipped it.
    """
    path = target_path(root, MODEL_MAP)
    if not os.path.exists(path):
        warning(
            "the installed system has no {} — the console keymap cannot be resolved and "
            "KEYMAP will be left as the image shipped it".format(MODEL_MAP)
        )
        return None

    exact = None
    plain = None
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                fields = line.split()
                if len(fields) < 4:
                    continue
                console, xlayout, _xmodel, xvariant = fields[0], fields[1], fields[2], fields[3]
                if xlayout.split(",")[0] != layout:
                    continue
                if variant and xvariant == variant:
                    exact = console
                    break
                if not xvariant or xvariant == "-":
                    # The first no-variant row for this layout, not the last: the file lists the
                    # plainest form first and later rows are increasingly specific.
                    if plain is None:
                        plain = console
    except OSError as e:
        warning("could not read {}: {}".format(path, e))
        return None

    return exact or plain


def has_console_keymap(root, keymap):
    """Does the target actually carry that keymap file?

    KEYMAP names a file under /usr/share/keymaps, and a name systemd cannot resolve leaves the
    console on its built-in default with one line in the journal nobody reads. sys-apps/kbd lays
    them out by architecture and sub-directory, so this walks rather than guessing a path.
    """
    root_dir = target_path(root, CONSOLE_KEYMAPS)
    if not os.path.isdir(root_dir):
        # Not a reason to refuse: an image that ships no console keymaps at all has nothing for
        # KEYMAP to name, and writing one would be writing a name into a void.
        return False
    wanted = (keymap + ".map", keymap + ".map.gz", keymap + ".inc")
    for _dirpath, _dirnames, filenames in os.walk(root_dir):
        for name in filenames:
            if name in wanted:
                return True
    return False


def write_vconsole(root, keymap):
    path = target_path(root, "/etc/vconsole.conf")
    lines = []
    if os.path.exists(path):
        # REWRITTEN KEY BY KEY, not replaced: the image's /etc/vconsole.conf may carry FONT= or
        # anything else, and a job that dropped those would be changing settings it was not asked
        # about.
        with open(path, "r", encoding="utf-8") as f:
            lines = [l.rstrip("\n") for l in f if not l.startswith("KEYMAP=")]
    lines.append("KEYMAP={}".format(keymap))
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(path, 0o644)
    debug("keyboardsetup: {} KEYMAP={}".format(path, keymap))


def write_xorg(root, layout, variant):
    path = target_path(root, "/etc/X11/xorg.conf.d/00-keyboard.conf")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    body = [
        "# Written by the installer. systemd-localed reads and rewrites this file; kwin_wayland",
        "# started with --locale1 takes its layout from localed.",
        'Section "InputClass"',
        '        Identifier "system-keyboard"',
        '        MatchIsKeyboard "on"',
        '        Option "XkbLayout" "{}"'.format(layout),
        '        Option "XkbModel" "{}"'.format(XKB_MODEL),
    ]
    if variant:
        body.append('        Option "XkbVariant" "{}"'.format(variant))
    body.append("EndSection")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(body) + "\n")
    os.chmod(path, 0o644)
    debug("keyboardsetup: {} XkbLayout={} XkbVariant={}".format(path, layout, variant or ""))


def run():
    root = libcalamares.globalstorage.value("rootMountPoint")
    if not root:
        return (
            _("Configuration Error"),
            _("No rootMountPoint is set — <pre>{!s}</pre> did not run.").format("keyboardsetup"),
        )

    layout = libcalamares.globalstorage.value("keyboardLayout")
    variant = libcalamares.globalstorage.value("keyboardVariant") or ""
    if not layout:
        # NOT AN ERROR, for the same reason localesetup's missing zone is not one: the image ships
        # KEYMAP=us and an X11 default to match, which is a correct answer for a machine nobody
        # told otherwise. The `keymap` page publishes its default from setConfigurationMap(), so
        # reaching here means the page is not in the sequence.
        warning(
            "no keyboardLayout in GlobalStorage; leaving the image's keyboard configuration"
        )
        return None

    try:
        write_xorg(root, layout, variant)
    except OSError as e:
        return (
            _("Configuration Error"),
            _("Could not write the keyboard configuration: {!s}").format(e),
        )

    keymap = console_keymap(root, layout, variant)
    if not keymap:
        warning(
            "no console keymap for X11 layout {}{}; KEYMAP is left as the image shipped it. "
            "The graphical session is unaffected — it reads the X11 file above.".format(
                layout, " ({})".format(variant) if variant else ""
            )
        )
        return None
    if not has_console_keymap(root, keymap):
        warning(
            "kbd-model-map resolves {} to console keymap {}, which the installed system does "
            "not carry; KEYMAP is left as the image shipped it".format(layout, keymap)
        )
        return None

    try:
        write_vconsole(root, keymap)
    except OSError as e:
        return (
            _("Configuration Error"),
            _("Could not write the console keymap: {!s}").format(e),
        )

    return None
