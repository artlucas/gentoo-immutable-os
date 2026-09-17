# 27 — The words that never reached the catalogue, and the rows that take a click

The installer speaks nine languages. It actually speaks one and a half.

The branding catalogue ([plan/22](22-installer-language-page.md)) translates every `tr()` the
five custom modules say in C++ — and the applications page, built last with all its words as
`AppsConfig` properties, is fully translated because of it. But the accounts and disk pages say
most of their words in QML, and the builder's lupdate (dev-qt/qttools 6.11) is built without QML
support, so a `qsTr()` there has never once reached a `.ts` file. Sixty-two C++ strings that *did*
reach the catalogue have sat unfinished since plan/22 — the accounts page and the disk page render
English in all eight translated languages, and the two dialogs plan/26 added ask their one
question in English too. The sidebar's About and Debug buttons, `qsTr()` in branding QML, are in
the same position.

This plan finishes the sentence plan/25 §4 started: **every user-visible string in every custom
module becomes a `tr()`'d C++ property**, the two retranslate halves arrive in the one module
missing them, and the catalogue is actually filled — all eight languages, all contexts, including
the sixty-two old entries and the dialogs. Alongside the words, three smaller repairs the pages
have earned: the password error that sits a row away from its field, the apps page's radio labels
that don't respond to a click on their own text, and the custom list's rows that lead with a
Flathub identifier nobody chose to read.

## 1. The treatment, applied to the two pages that never had it

The pattern is [plan/25 §4]'s and needs restating only once: a string the page shows becomes a
property on its Config object, whose getter says `tr("...")`, whose NOTIFY is `retranslated`, and
whose value therefore reaches the branding catalogue (lupdate reads it out of the `.cpp`), changes
when the language does (`CALAMARES_RETRANSLATE_SLOT` re-emits), and re-says in the QML binding
(the ViewStep's `engine()->retranslate()` re-evaluates it). After this plan, `qsTr()` appears in
no module QML at all — the assertion test-installer.sh:1266 has held over the apps page since it
was written now holds everywhere.

**Accounts** gains roughly forty string properties. The local form's labels ("Your name:",
"Username:", "Password:", "Repeat password:"), the auto-login checkbox plan/26 added, the
chooser's heading and warning and the three modes' title/subtitle/needs (the QML `modes` array
keeps its shape — one array, read twice, [plan/21 §1] — only its string sources move to
`accounts.localModeTitle` and siblings), the domain form's eighteen, the managed form's five, the
computer-name label, and the weak-password dialog's title, fallback line and both buttons.
Deduplicated where LocalForm and DomainForm say the same thing ("Username:", "Password:",
"Repeat password:", "The two passwords are not the same." — one entry each).

Two kinds of string deliberately do **not** move: example data that is a proper noun
("Ada Lovelace", "ada", `corp.example.com`, `Administrator`, the OU and domain-group and
enrolment-code examples) stays a plain QML literal, the same argument apps.conf makes for
application names; and strings that are already C++ properties (`passwordMessage` and its
siblings) stay as they are.

The accounts module is also the one QML module with **neither retranslate half** — no slot on the
config, no engine call in the view step (plan/22 §8's second known limit). Both arrive:
`CALAMARES_RETRANSLATE_SLOT(&AccountsConfig::retranslate)` emitting `retranslated()` and calling
`revalidate()` (so the cached validity messages, which today re-say only on the next keystroke,
follow a language change too), and the `engine()->retranslate()` line in `AccountsViewStep` that
Language, Disk and Apps have carried all along.

`PasswordCheck.cpp` stops saying `QObject::tr` and says `tr`: its two strings land in the
`PasswordCheck` context, which matches the file's stem — the position check-translations.py check
5 demands of any *finished* context, and these are about to be finished.

**Disk** gains eleven, both halves already in place: the rescan button, the two no-disks
messages (the `%1` minimum composed on the C++ side of the property), the layout heading, the
encrypt checkbox, "Not yet available", the loss-summary line the panel has carried since plan/24,
and the erase dialog's title, subtitle, and both buttons. The dialog's subtitle — plan/26's
`"%1 — %2"` of disk title and loss summary, with its generic fallback — moves into the getter
whole (`confirmSubtitle`), because a format string with two substituted C++ strings is three
translations' worth of moving parts for one property; `retranslated` is re-emitted when the
selection changes so the composition follows it.

## 2. Descriptions, and the one precedent for conf-sourced words

The custom list's rows will show a description under each application name, and a description is
a sentence, not a proper noun — leaving it English in a Japanese interface would undo the point
of §1. But descriptions are facts about Flathub applications, and facts about Flathub belong in
[apps.conf](../config/calamares/modules/apps.conf) beside the `name` and `icon`, not in C++.

The repo already has the mechanism for words whose source is a conf file rather than a source
file: the language page's names table, `LanguageNames`. The conf value is passed through
`QCoreApplication::translate("<context>", value)` at runtime, and the context is hand-maintained
in the `.ts` files — a **pseudo-context**, exempt from check-translations' source-vs-catalogue
checks because its authority is the conf, not the code.

So: `description:` keys in both apps.conf copies (six one-liners), a fourth key in the C++ copy
loop, `QCoreApplication::translate("AppsDescriptions", …)` around each, and `PSEUDO_CONTEXTS`
grows by one. The `apps` QVariantList property gives up `CONSTANT` for `NOTIFY retranslated` —
the list is rebuilt when the language changes, because the descriptions inside it are translated
at build-list time. Selection lives in `selectedIds`, so a rebuild costs nothing but paint.

## 3. The sidebar's two stragglers

`calamares-sidebar.qml`'s About and Debug buttons say `qsTr("About")` / `qsTr("Debug")` in a file
no lupdate reads (plan/26 §5's willingly-inherited limit). `qsTranslate("CalamaresSidebar", ...)`
names the context explicitly, which a hand-maintained `.ts` entry can then serve at runtime —
the branding translator is installed on the app, and `qsTranslate` consults it by
(context, source). `CalamaresSidebar` becomes the third pseudo-context. If the runtime lookup
does not resolve — verified in the VM, not assumed — the entries are dropped and the documented
limit returns; nothing else changes.

## 4. The un-vanish chore, ended

A pseudo-context's entries are invisible to lupdate, so every `update-translations.sh` run marks
them `vanished` — lrelease then drops them and the language picker's second line goes missing
until somebody flips them back by hand. That has been a standing known limit since plan/22. The
script now does the flipping itself: after lupdate, a python step strips `type="vanished"` from
every pseudo-context entry (`LanguageNames` included — the original chore dies with the same
stroke). Their translations survive the round-trip because `-no-obsolete` is deliberately not
passed.

## 5. Filling the catalogue

After the code moves, `update-translations.sh` runs once (in the builder container, as ever), and
then every unfinished entry in all eight non-English languages is filled: the ~42 new accounts
properties, the 11 disk ones, `AppsDescriptions` (6), `CalamaresSidebar` (2), and the sixty-two
old ones — AccountsConfig's 29 enrol/verify/validity/summary strings, DiskConfig's 22,
DiskModel's 7 row titles, the two ViewStep sidebar names, Requirements' four configuration-error
strings. Placeholders (`%1`) are preserved; the wording follows the tone the finished AppsConfig
and GreetingPage entries set. These are reviewable drafts, not native-speaker work — the known
limit at the end of this document says so again.

## 6. The password error, glued to its field

The local form is a `Kirigami.FormLayout`, and the red password message sits one form-row away
from its field — with the score meter's row in between whenever a password exists, which is
exactly when the message shows. The fix is the shape ComputerNameField.qml already uses for the
hostname: the field and its message become **one form row**, a `ColumnLayout` with
`spacing: 0` and the `FormData.label` on the column — the message is the immediately following
sibling, no spacing, no margin. Inside the password column the order is field, error, meter: the
error answers the field, the meter scores it. The repeat-password field and its mismatch message
get the same treatment, and so does the username field, because a page that glues one red
message and gaps another has explained nothing.

## 7. The apps page takes the click, and loses the identifier

The three mode rows put their text in `QQC2.Label`s beside bare `RadioButton`s — clicking the
label does nothing. Each label block is now wrapped in a `MouseArea` (pointing-hand cursor, the
sidebar-button precedent; `enabled` following the radio's, so the offline rule keeps refusing
quietly) whose click sets the mode. The custom list's rows are rebuilt the same way and more
thoroughly: the Flathub identifier label is deleted — the id remains the key C++ and the job
exchange, it just stops being the sentence the page leads with — and each row is a checkbox
beside a clickable block of icon, `name`, and `description` underneath (small, dimmed). Clicking
anywhere on the block toggles that application's checkbox.

## 8. Tests

test-installer.sh: the two string pins that move with the code (the auto-login checkbox text at
:493, the loss-summary line at :985) are repointed at the `.cpp` files that now say them; the
no-`qsTr()` assertion :1266 extends to the accounts module's five QML files and Disk.qml; new
assertions pin the descriptions (present in both confs, agreeing, copied by C++, wrapped in the
`AppsDescriptions` translate call, `apps` notifying `retranslated`), the accounts retranslate
halves (the slot in AccountsConfig, `engine()->retranslate()` in AccountsViewStep, mirroring
:1027-1030), PasswordCheck's plain `tr(`, the sidebar's `qsTranslate("CalamaresSidebar"`, and
every `.ts` finishing the new contexts. test-managed.sh: its "the QML uses qsTr()" assertion
(:568, written when qsTr *was* the house pattern) flips to forbid the call, with the toolchain
reason; the binding-resolution sweep picks up the new `accounts.*` names mechanically.

## 9. Known limits

- **The translations are mine.** Eight languages, ~95 sources, authored to be reviewed. A
  native speaker's pass over `lang/` is the follow-up this plan owes.
- **About/Debug re-say only at creation.** Calamares' own sidebar engine gets no
  `engine()->retranslate()` from our code; a language changed mid-session leaves the two buttons
  in the old language until restart. The step names do not share this (they re-say through the
  widget model).
- **`AppsDescriptions` drift is silent.** The conf text is the lookup key: edit one without the
  `.ts` and the description falls back to English — the same contract `LanguageNames` has always
  had.
- **A full end-to-end install to a real (VM) disk remains untested** — the standing gap since
  plan/24, unchanged by this plan.

## Changes to other documents

- `config/calamares/README.md` — the module table's accounts/disk/apps notes mention the
  string-property rule now covering every module, if the table speaks of qsTr at all.
- `scripts/update-translations.sh` — the post-lupdate un-vanish step and its comment.
- `scripts/lib/check-translations.py` — `PSEUDO_CONTEXTS` grows to three, with the argument for
  each.
