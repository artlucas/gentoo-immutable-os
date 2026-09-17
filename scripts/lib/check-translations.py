#!/usr/bin/env python3
"""Check the installer's branding translations against config/languages.conf (plan/22 §4).

ONE IMPLEMENTATION, TWO CALLERS: stage 40 runs this before it compiles the .qm files, and
tests/test-installer.sh runs it offline. Duplicating the rules in a shell version of each would be
two chances to disagree about what a valid translation file is.

WHAT IT IS ACTUALLY PROTECTING. Qt's translation lookup has no failure mode. A <source> that does
not match the C++ or QML byte for byte is not an error, not a warning and not a log line -- it is a
string that stays in English, on one screen, in one language, which is exactly the kind of thing
nobody finds without booting the medium in all nine. So the matching is checked here, at build
time, where it can fail loudly.

Checks, in order of how quietly they would otherwise fail:

  1. every language in the table except `en` has a .ts file            (else: a whole language is English)
  2. every .ts declares language="<id>"                               (else: lrelease picks the wrong plural rules)
  3. LanguageNames carries a finished translation for every row        (else: the picker's second line is English)
  4. every other <source> appears verbatim in the module sources       (else: that string is English, silently)
  5. every context's strings live in the file that context names       (else: a whole context is English)
  6. no .ts file for a language the table does not offer               (else: dead weight nobody maintains)

Check 4 is the one with a deliberate hole in it, and it is worth knowing about: it proves every
string IN the .ts files matches the code, and says nothing about strings in the code that are in no
.ts file. Those fall back to English, which is correct behaviour rather than a defect -- the
accounts page is in that position today. `scripts/update-translations.sh` is what closes it.

Check 5 exists because of plan/23, and it is the one check 4 cannot do. A Qt context IS a class
name: moving the greeting screen out of the language module moved four strings from LanguageConfig
into GreetingPage and GreetingConfig without changing one character of any of them. Check 4 passes
that mistake -- every <source> really does still appear in the module sources -- and all four
strings would have been English, because Qt looks them up under a class that no longer says them.
So check 5 asks the sharper question: does the file this context NAMES contain this string? It
takes "the file this context names" to be the .cpp/.h/.qml whose stem is the context name, which is
the layout every module here uses (Foo's tr() calls live in Foo.cpp) and upstream's too.
"""
import argparse
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

# checker/ is the greeting module's vendored copy of upstream's requirements box (plan/23 section 2),
# and its two translatable strings are in our catalogues -- so the directory has to be scanned or
# check 4 would reject them. Listed rather than globbed with */: a new subdirectory in a module is a
# deliberate thing and should be a deliberate line here.
SOURCE_GLOBS = ("*.cpp", "*.h", "qml/*.qml", "checker/*.cpp", "checker/*.h")

# LanguageNames is not a class and never will be: it is a hand-written context whose sources arrive
# at runtime out of config/languages.conf, through QCoreApplication::translate(). Checks 4 and 5
# both skip it, and the table is its authority instead.
#
# AppsDescriptions (plan/27 §2) is the same bargain one directory over: the applications page's
# conf-sourced descriptions, looked up by their own English text through translate() in
# AppsConfig.cpp -- the conf is its authority. CalamaresSidebar (plan/27 §3) is the branding
# sidebar's qsTranslate() context, hand-maintained because the builder's lupdate cannot read QML
# at all; the sidebar file itself, outside every --source-dir, is its authority.
PSEUDO_CONTEXTS = {"LanguageNames", "AppsDescriptions", "CalamaresSidebar"}


def read_table(path):
    rows = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = [f.strip() for f in line.split("|")]
        if len(fields) != 4:
            sys.exit("%s:%d: expected 4 '|'-separated fields, got %d" % (path, lineno, len(fields)))
        rows.append(dict(zip(("id", "locale", "label", "english"), fields)))
    if not rows:
        sys.exit("%s names no languages" % path)
    return rows


def collapse_literals(text):
    """Join C++/QML adjacent string literals the way the compiler does.

    A long tr() argument is written as several literals on several lines; the .ts file holds the
    single string they concatenate to. Without this, every wrapped string looks like a mismatch.
    """
    return re.sub(r'"[ \t]*(?://[^\n]*)?\n\s*"', "", text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--table", required=True, type=pathlib.Path)
    ap.add_argument("--lang-dir", required=True, type=pathlib.Path)
    ap.add_argument("--source-dir", action="append", default=[], type=pathlib.Path,
                    help="a module's files/ directory; repeatable. Enables check 4.")
    args = ap.parse_args()

    rows = read_table(args.table)
    problems = []

    blob = ""
    # stem -> that file's text, joined across the .h/.cpp pair. Qt's context is the class that
    # called tr(), and in this tree (and upstream's) a class named Foo is declared in Foo.h and
    # says its strings in Foo.cpp -- so the stem is what a context has to be matched against.
    by_stem = {}
    for d in args.source_dir:
        if not d.is_dir():
            problems.append("--source-dir %s is not a directory" % d)
            continue
        for pattern in SOURCE_GLOBS:
            for f in sorted(d.glob(pattern)):
                content = f.read_text(encoding="utf-8")
                blob += content + "\n"
                by_stem[f.stem] = by_stem.get(f.stem, "") + content + "\n"
    collapsed = collapse_literals(blob)
    by_stem = {stem: collapse_literals(text) for stem, text in by_stem.items()}

    expected_ids = {r["id"] for r in rows if r["id"] != "en"}
    english_names = {r["english"] for r in rows}

    for r in rows:
        if r["id"] == "en":
            continue  # the source language: tr() already answers in English
        ts_path = args.lang_dir / ("calamares-installer_%s.ts" % r["id"])
        if not ts_path.is_file():
            problems.append(
                "%s is missing. config/languages.conf offers %s (%s), so without it that whole "
                "language gets an English installer." % (ts_path, r["id"], r["label"]))
            continue
        try:
            root = ET.parse(ts_path).getroot()
        except ET.ParseError as e:
            problems.append("%s is not well-formed XML: %s" % (ts_path, e))
            continue

        declared = root.get("language")
        if declared != r["id"]:
            problems.append("%s declares language=%r, expected %r — lrelease takes its plural "
                            "rules from that attribute." % (ts_path, declared, r["id"]))

        finished = {}
        for ctx in root.findall("context"):
            name_el = ctx.find("name")
            ctx_name = name_el.text if name_el is not None else "<unnamed>"
            for msg in ctx.findall("message"):
                src_el, tr_el = msg.find("source"), msg.find("translation")
                src = src_el.text if src_el is not None else None
                if not src:
                    problems.append("%s: a <message> in context %s has no <source>" % (ts_path, ctx_name))
                    continue
                text = (tr_el.text or "") if tr_el is not None else ""
                kind = tr_el.get("type") if tr_el is not None else None
                if kind in ("unfinished", "vanished") or not text.strip():
                    continue  # falls back to the source string, which is correct behaviour
                finished.setdefault(ctx_name, set()).add(src)

                # Check 4. The pseudo-contexts are exempt: their sources arrive at runtime out
                # of files no source-dir scan covers (languages.conf, apps.conf, the branding
                # sidebar's qsTranslate calls), so there is no literal in any module source to
                # match them against — their own files are their authority.
                if ctx_name not in PSEUDO_CONTEXTS and args.source_dir and src not in collapsed:
                    problems.append(
                        "%s: context %s has <source>%r, which appears in none of the module "
                        "sources. Qt will never look that string up, so it stays English."
                        % (ts_path, ctx_name, src))

            # Check 5, once per context. Only FINISHED messages are examined, for the same reason
            # check 4 skips the others: an unfinished entry translates to nothing and falls back to
            # English by design.
            done = finished.get(ctx_name, set())
            if args.source_dir and done and ctx_name not in PSEUDO_CONTEXTS:
                if ctx_name not in by_stem:
                    problems.append(
                        "%s: context %s names no file in the module sources. Qt takes a context "
                        "from the class that called tr(), so every string in it is looked up under "
                        "a name nothing uses and stays English." % (ts_path, ctx_name))
                else:
                    stray = sorted(s for s in done if s not in by_stem[ctx_name])
                    if stray:
                        problems.append(
                            "%s: context %s carries %s, which %s.{h,cpp,qml} does not say. The "
                            "string exists somewhere in the sources, so check 4 is happy -- but Qt "
                            "looks it up under the class that says it, and that is a different "
                            "one. Did it move?"
                            % (ts_path, ctx_name, ", ".join(repr(s) for s in stray), ctx_name))

        missing = sorted(english_names - finished.get("LanguageNames", set()))
        if missing:
            problems.append(
                "%s: the LanguageNames context has no finished translation for %s. That is the "
                "second line of a row in the picker, and it would render in English."
                % (ts_path, ", ".join(repr(m) for m in missing)))

    for ts_path in sorted(args.lang_dir.glob("calamares-installer_*.ts")):
        found = ts_path.name[len("calamares-installer_"):-len(".ts")]
        if found not in expected_ids:
            problems.append("%s is for '%s', which config/languages.conf does not offer — either "
                            "add the row or delete the file." % (ts_path, found))

    if problems:
        print("translation check FAILED:", file=sys.stderr)
        for p in problems:
            print("  - %s" % p, file=sys.stderr)
        return 1
    print("translations: %d languages, LanguageNames complete, every source string matched"
          % len(expected_ids))
    return 0


if __name__ == "__main__":
    sys.exit(main())
