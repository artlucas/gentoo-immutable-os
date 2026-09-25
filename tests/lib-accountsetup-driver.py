#!/usr/bin/env python3
"""Load a rendered Calamares local-module with a stub libcalamares, and call one function on it.

Calamares' python modules import `libcalamares`, which exists only inside the installer — so the
offline suite cannot import one without this. What it buys is worth the twenty lines: the domain
join and the enrolment transplant used to live in a bash shim and a separate job that
tests/test-domain.sh and tests/test-managed.sh could drive directly, and after plan/21 they are
functions in a Calamares module. Asserting their argv with grep would have been a strictly weaker
test of code that got MORE complicated, not less. Named for `accountsetup`, its first caller, but
`importlib.util.spec_from_file_location` does not care whose module it loads — tests/test-installer.sh
drives `imagedeploy`'s own `check_no_live_leakage()` through the same harness (plan/34 §7.2/§9,
checkpoint 4's review), for the same reason: a leak check's keep/erase branching is exactly the
kind of thing a source grep cannot tell apart from the outside.

Usage:  lib-accountsetup-driver.py <main.py> <function> <root>
        GS_JSON, CONF_JSON, TOOL (the stub that stands in for <id>-managed / <id>-domain),
        LIVE_USER and KEEP come from the environment. Prints the function's return value, or
        `None`.
"""
import importlib.util
import json
import os
import sys
import types


def install_stub_libcalamares(gs_values, configuration):
    lc = types.ModuleType("libcalamares")

    utils = types.ModuleType("libcalamares.utils")
    utils.debug = lambda msg: sys.stderr.write("debug: %s\n" % msg)
    utils.warning = lambda msg: sys.stderr.write("warning: %s\n" % msg)
    # gettext_path() returning None makes gettext.translation fall back to NullTranslations, which
    # is what the module's `fallback=True` is for. The installer supplies a real path.
    utils.gettext_path = lambda: None
    utils.gettext_languages = lambda: ["en"]

    class GlobalStorage:
        def __init__(self, values):
            self._values = values

        def value(self, key):
            return self._values.get(key)

        def insert(self, key, value):
            self._values[key] = value

    job = types.ModuleType("libcalamares.job")
    job.configuration = configuration

    lc.utils = utils
    lc.job = job
    lc.globalstorage = GlobalStorage(gs_values)

    sys.modules["libcalamares"] = lc
    sys.modules["libcalamares.utils"] = utils
    sys.modules["libcalamares.job"] = job
    return lc


def main(argv):
    path, func, root = argv[0], argv[1], argv[2]
    gs_values = json.loads(os.environ.get("GS_JSON", "{}"))
    configuration = json.loads(os.environ.get("CONF_JSON", "{}"))
    lc = install_stub_libcalamares(gs_values, configuration)

    spec = importlib.util.spec_from_file_location("accountsetup", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    # The stub stands in for both tools; which one a given call uses is the point of the call.
    tool = os.environ.get("TOOL")
    if tool:
        mod.MANAGED_CLI = tool
        mod.DOMAIN_CLI = tool

    if func == "run":
        result = mod.run()
    elif func == "join_domain":
        result = mod.join_domain(root, lc.globalstorage, os.environ.get("JOIN_PASSWORD", ""))
    elif func == "transplant_enrolment":
        result = mod.transplant_enrolment(root, lc.globalstorage)
    elif func == "write_hostname":
        result = mod.write_hostname(root, lc.globalstorage, configuration)
    elif func == "check_no_live_leakage":
        # imagedeploy's own DeployError is not the (title, message) tuple run() converts it to —
        # catch it here the same way run()'s own try/except does, so a caller that wants the
        # message sees the same shape drive_join() etc. already hand back.
        live_user = os.environ.get("LIVE_USER", "live")
        keep = os.environ.get("KEEP") == "1"
        try:
            result = mod.check_no_live_leakage(root, live_user, keep)
        except mod.DeployError as e:
            result = (e.title, e.message)
    elif func == "copy_dir_with_progress":
        # `root` is unused here; SRC/DEST/TOTAL_BYTES carry the arguments instead, because this
        # one isn't a job function with a `root` of its own — it's the Flatpak-copy helper,
        # fixture-tested for robustness against a pre-existing destination (checkpoint 4 review).
        src = os.environ["SRC"]
        dest = os.environ["DEST"]
        total_bytes = int(os.environ.get("TOTAL_BYTES", "0"))
        mod.copy_dir_with_progress(src, dest, total_bytes, lambda f: None)
        result = None
    else:
        raise SystemExit("unknown function %r" % func)

    print("None" if result is None else json.dumps(list(result)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
