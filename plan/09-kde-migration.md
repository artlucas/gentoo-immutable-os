# 09 — KDE Plasma Migration

**Status: EXECUTED 2026-08-23. BUILT AND BOOTED 2026-08-25 (image `0.2.0`).** Every change
below is in the tree, and the substance has folded back into plan/03 (package set), plan/06
(pruning) and plan/08 (roadmap), which are now the live documents. This file is kept as the
record of *why*, and of what the plan got wrong.

The full pipeline runs green end to end: 628 packages to the image root, stage 50's prune
assertions all pass, both stage-70 smoke boots report
`graphical=yes failed_units=0 resolved=yes dns=yes`, and stage 80 assembles a release. The
committed `config/portage/expected-packages.txt` is 615 entries, regenerated from this build.
Measured sizes and the settled Python chain are in plan/06; the audit of the generated allowlist
and the remaining open items are at the end of this file.

**What is still unverified is everything a serial port cannot see.** Stage 70 asserts that
`graphical.target` was reached, not that anything was drawn on it. The manual QEMU pass in §6 —
autologin landing in a Wayland session, the screen locking, Discover, `smb://`, Baloo staying
basic — has **not** been done, and until it is, "the desktop works" is not a claim this document
supports.

Getting the dependency graph to resolve took eleven USE corrections the plan did not predict;
they are recorded in "What the plan got wrong" below.

## Why

The native set is deliberately tiny — *"if it touches hardware, sessions or system services →
native; if it's an application window → Flatpak"* (plan/03). Today that native desktop is GNOME:
the `desktop/gnome/systemd` profile, `@desktop` = gnome-shell / mutter / GDM / nautilus /
gnome-console / gnome-software, and roughly 40 lines of `package.use` tuned around GNOME's
dependency graph — three separate `-X` flags to keep the Xorg server out,
`-gnome-online-accounts` to keep `webkit-gtk` out, `-qt6` on four packages to keep Qt out
entirely.

We are switching the desktop to KDE Plasma 6 and removing GNOME. The minimality rule carries
over unchanged: the KDE set is a **1:1 functional mirror** of today's GNOME set, not a full
Plasma install. Firefox stays a Flatpak. Everything below the desktop — boot, EROFS root, UKI,
A/B sysupdate, the `/etc` overlay, the plymouth splash, image assembly — is untouched.

## Decisions

| | |
|---|---|
| App set | 1:1 mirror of today's GNOME set. No Ark, no Kate, no Okular/Gwenview |
| Display manager | **Plasma Login Manager** (`kde-plasma/plasma-login-manager`), Wayland greeter, autologin as `$LIVE_USER` |
| Session | Wayland-only, Xwayland for legacy clients, **no** xorg-server (as today) |
| GTK | **Kept**, for Flatpak theming — `breeze-gtk` + `kde-gtk-config` |
| Builder tools | `gnome-base/librsvg` stays in the builder container (build-only, never in the image) |

> **Provenance.** Every package name, USE flag, keyword and dependency below was checked against
> the Gentoo ebuild repository inside the existing `immos-builder` image (tree timestamp
> *Thu 20 Aug 2026*, matching `SNAPSHOT_DATE=20260819`). Anything still unverified is called out
> as such, and the open items at the end of this document are what genuinely cannot be settled
> without a build.

### Plasma Login Manager, not SDDM

Plasma Login Manager (PLM) is KDE's SDDM replacement, released alongside Plasma 6.6 and forked
from SDDM itself. It is the direction the ecosystem is moving — Fedora 44 ships it as the default
across every KDE variant — and for this image specifically it is the better fit: it reuses
`kwin` as its greeter compositor rather than starting a second one, which matters in an
image that is Wayland-only by construction.

**The one cost, stated plainly:** `kde-plasma/plasma-login-manager` is `~amd64` at the pinned
snapshot — the *only* package in the whole KDE set that is not stable-keyworded — whereas
`x11-misc/sddm` has a stable version (`0.21.0_p20250502-r1`). So this choice buys a keyword
exception that SDDM would not have needed. `config/portage/package.accept_keywords/image` opens
with "Keep empty if possible — stable amd64 only", so this is a deliberate departure from that
rule, recorded here rather than slipped in.

Pin the **`6.6.6`** ebuild specifically, not the newest. `plasma-login-manager-6.6.6` needs
`QTMIN=6.10.0`, satisfied by the stable `dev-qt/qtbase-6.11.1`; both `6.6.6-r1` and `6.7.4-r1`
raise it to `>=6.11.2`, which is `~amd64` and would drag a `~amd64` Qt **and** a `~amd64`
Plasma 6.7.4 stack in behind it. One `~amd64` package, not a hundred.

### The one consequence worth stating up front

Keeping the GTK theming bridge means *"remove all GNOME"* cannot be literal. `gui-libs/gtk` and
`x11-libs/gtk+` hard-RDEPEND `x11-themes/adwaita-icon-theme`, which in turn RDEPENDs
`gnome-base/librsvg`; `dev-libs/glib` is a dependency of flatpak, NetworkManager, polkit and
pipewire regardless of desktop. So the ban is scoped to **GNOME desktop components**, with a
short, explicitly enumerated library residue (§4). Dropping `breeze-gtk`/`kde-gtk-config` later
removes almost all of that residue in one edit — that is the lever if it turns out to be
unacceptable.

---

## 1. Package sets and Portage config

### `config/build.conf`

- `PROFILE="default/linux/amd64/23.0/desktop/plasma/systemd"` (was `desktop/gnome/systemd`).
- Splash comment block (~lines 47–56): *"from initrd through to the GDM hand-off"* → Plasma
  Login Manager.
- `FLATPAK_PREINSTALL` unchanged (`org.mozilla.firefox`).

### `config/portage/sets/desktop` — full rewrite

Preserve the `#cjk` / `#printing` marker comments; `filter_set_file()`
(`scripts/lib/common.sh:386`) strips those lines when the `build.conf` switches are 0, and
`net-print/cups` **and** `kde-plasma/print-manager` must both carry `#printing`.

```
# @desktop — minimal KDE Plasma 6 Wayland (plan/03).
kde-plasma/plasma-desktop
kde-plasma/plasma-workspace
kde-plasma/kwin
kde-plasma/systemsettings
kde-plasma/plasma-systemmonitor
kde-plasma/plasma-nm
kde-plasma/plasma-pa
kde-plasma/powerdevil
kde-plasma/bluedevil
kde-plasma/kscreen
kde-plasma/polkit-kde-agent
kde-plasma/kwallet-pam
kde-plasma/discover
kde-plasma/xdg-desktop-portal-kde
kde-plasma/breeze
kde-plasma/breeze-gtk            # GTK theming bridge for Flatpak apps
kde-plasma/kde-gtk-config        #   "
kde-plasma/plasma-workspace-wallpapers
kde-plasma/plasma-login-manager  # the display manager; its System Settings KCM is built in
kde-plasma/plasma-login-sessions # /usr/share/wayland-sessions/plasma.desktop lives HERE
kde-frameworks/breeze-icons
kde-apps/dolphin
kde-apps/konsole
kde-apps/kio-extras              # the gvfs equivalent: trash, network, thumbnails
kde-plasma/print-manager         #printing
sys-power/power-profiles-daemon
media-video/pipewire
media-video/wireplumber
x11-base/xwayland
media-fonts/noto
media-fonts/noto-emoji
media-fonts/noto-cjk             #cjk
net-print/cups                   #printing
```

Dropped, with the reason recorded in the file's header comment the way the current one records
file-roller/gnome-text-editor:

- `media-fonts/cantarell` — Breeze uses Noto Sans, already in the set.
- `x11-themes/adwaita-icon-theme`, `x11-themes/gnome-backgrounds` — replaced by `breeze-icons`
  and `plasma-workspace-wallpapers`. adwaita-icon-theme returns only as a GTK RDEPEND.
- `sys-apps/xdg-desktop-portal-gtk` — `xdg-desktop-portal-kde` implements the full interface set
  (FileChooser, Settings, Screenshot, ScreenCast, Print, Inhibit, Account, GlobalShortcuts), so
  the GTK *backend* has no job. The GTK *theming* bridge is a separate thing and stays.
- `kde-plasma/sddm-kcm` — it hard-RDEPENDs `x11-misc/sddm`, so it goes with SDDM. PLM builds its
  own System Settings module (its DEPEND carries `kde-frameworks/kcmutils` for exactly that).

Two entries above are easy to get wrong and were checked against the tree:

- **`kde-plasma/print-manager`**, not `kde-apps/print-manager` — it lives in the `kde-plasma`
  category. Stable amd64 at `6.6.6`, `IUSE="+gtk"`.
- **`kde-plasma/plasma-login-sessions`** is what installs
  `/usr/share/wayland-sessions/plasma.desktop`. It is a `PDEPEND` of `plasma-workspace`, so it
  would arrive anyway — but it is listed explicitly because its `+wayland`/`X` flags are the
  real lever that decides whether an Xorg session exists (`X?` pulls `kde-plasma/kwin-x11`).
  Neither the display manager nor `plasma-workspace` provides the session files themselves.

### `config/portage/sets/base`

No package changes. Only the prose around `sys-apps/xdg-desktop-portal` in plan/03 mentions
`-gnome`; the set entry itself is desktop-agnostic.

### `config/portage/sets/buildhost`

Delete `gnome-extra/tecla` — it existed solely for `gnome-control-center`'s
`dependency('tecla')`. Keep the file's explanatory header: KDE may well need its own
configure-time RDEPEND-only entry, and the first build is what surfaces it. The failure
signature is a meson/cmake `Dependency ... found: NO` inside a *target* package build.

### `config/portage/make.conf.in`

```
USE="wayland pipewire screencast bluetooth vulkan vaapi \
     -doc -gtk-doc -examples -test \
     -handbook -telemetry -webengine -designer \
     -gnome -gnome-keyring -gnome-online-accounts -introspection"
```

Each new token earns its place:

- `-handbook` — KDE ships per-app DocBook handbooks; nothing in the image can render them (no
  khelpcenter), and they land in `/usr/share/doc/HTML`, already deleted by stage 50.
- `-telemetry` — drops `dev-libs/kuserfeedback` and the KDE telemetry surface.
- `-webengine` — the structural guard against `dev-qt/qtwebengine` (a Chromium build). Backed by
  a hard mask in `package.mask/image`.
- `-designer` — Qt Designer plugins have no consumer in an image with no IDE.
- `-gnome`, `-gnome-keyring` — global levers that stop packages offering GNOME integration from
  pulling it in. This is the same flag that makes `x11-misc/xdg-utils[-gnome]` load-bearing
  today (see the long note at `package.use/image:138-159`).
- `-introspection` — dropped from the *global* set. It was there because *"gjs and gnome-shell
  load GObject typelibs at runtime"* (plan/03), which is no longer true of anything in the image.
  `dev-libs/glib introspection` stays as a per-package line so the binhost's glib binpkg still
  matches. **Rollback if this bites:** if any surviving package dlopens a typelib, put
  `introspection` back globally and revert the `girepository-1.0` prune in §3.

### `config/portage/package.use/image` — rewrite the desktop half

**Keep unchanged:** `sys-apps/systemd`, `app-admin/sudo`, `x11-drivers/nvidia-drivers` (`-X` is
still right — Wayland-only), `sys-kernel/linux-firmware`, `media-video/pipewire`,
`net-misc/networkmanager` (keep `modemmanager` — `plasma-nm[modemmanager]` is the
mobile-broadband UI, the same call plan/03 made for the control-center panel),
`media-libs/mesa`, `sys-kernel/installkernel`, `sys-kernel/gentoo-kernel-bin`,
`sys-boot/plymouth`, `x11-libs/libdrm`, `dev-libs/glib`, `gui-libs/gtk`, `x11-libs/gtk+`,
`media-libs/vulkan-loader`, `x11-libs/cairo`, `x11-libs/libxkbcommon`, `media-video/ffmpeg`,
`net-print/cups`, `x11-base/xwayland`, `media-libs/libpulse`, `media-plugins/alsa-plugins`,
`media-libs/freetype`, `media-libs/libglvnd`, `sys-libs/minizip-ng`, `x11-misc/xdg-utils`,
`app-crypt/libb2`. Drop `introspection` from the gtk/gtk+ lines when the global flag goes.

**Delete outright** (their packages are gone): the whole `# ---- GNOME session ----` block
(`gnome-software`, `gdm`, `gnome-control-center`, `evolution-data-server`, `nautilus`,
`localsearch`, `mutter`), `dev-cpp/cairomm`, `app-crypt/gcr`, `media-libs/libcanberra`,
and `media-libs/tiff jpeg` — that last one belonged to the printer-panel cascade, where it fed
`dev-python/pillow` via docutils behind `app-admin/system-config-printer`.
`kde-plasma/print-manager` talks to CUPS directly, so system-config-printer and pillow both go.

**Replace, rather than delete, the two `app-text/poppler` lines.** They currently read `cairo`
(so `localsearch[pdf]` can extract PDF text and thumbnails) and `-qt6` (to keep `dev-qt/qtbase`
out of a GNOME-only image). Both premises invert here: PDF indexing now runs through
`kde-frameworks/kfilemetadata[pdf]`, which requires `app-text/poppler[qt6(-)]`, and qtbase is
this image's own toolkit. One line replaces both — see the block below.

**Keep `net-fs/samba client`,** and retarget the `# ---- printer panel cascade ----` header
comment above it. It is no longer the GNOME printer panel that holds samba — it is
`kde-apps/kio-extras[samba]`, kept deliberately for `smb://` in Dolphin (see `package.use`
below). State the consequence in that comment rather than leaving it to be rediscovered: samba
lists `dev-lang/perl:=` and `dev-perl/Parse-Yapp` in COMMON_DEPEND with no USE guard, so **the
image still ships a perl interpreter**. That was already true under GNOME, at one more remove;
this change keeps it true and makes the reason a direct one.

`net-libs/ngtcp2 gnutls` is a REQUIRED_USE tiebreak — ngtcp2 wants exactly one crypto backend —
that appeared alongside samba's `net-libs/gnutls`. Since samba stays, leave the line in for the
first depgraph rather than guessing; drop it if `emerge -p @desktop` resolves without it.

**Invert the four anti-Qt lines:**

```
sys-auth/polkit             kde -gtk    # was "gtk introspection" — polkit[gtk] is what pulled
                                        # gnome-extra/polkit-gnome into the image
app-crypt/pinentry          qt6 ncurses -gtk -efl -emacs
dev-libs/appstream          qt6         # AppStreamQt — Discover's metadata backend
dev-libs/libportal          qt6 -gtk -vala
```

Keep `net-wireless/wpa_supplicant -gui` and rewrite its comment: the flag is still `gui`, not
`qt6`, and a standalone Qt supplicant UI is still redundant next to plasma-nm — but the
"-qt6 everywhere else" framing no longer applies.

Add a new `# ---- Plasma session ----` block. IUSE below is **read from the 6.6.6 ebuilds**, not
guessed:

```
# The display manager. Wayland greeter, no flags of its own (IUSE="test" only). It RDEPENDs
# kwin[lock] — see below — and sys-apps/systemd[pam], which is why "pam" joins the systemd line.
sys-apps/systemd                  boot policykit pam
# kwin has NO X flag: kde-plasma/kwin is Wayland-only and the X11 compositor is a separate
# package (kde-plasma/kwin-x11), which nothing here pulls. "lock" is NOT default-on and is
# required by plasma-login-manager — it is also the ONLY thing that puts a screen locker
# (kde-plasma/kscreenlocker) in the image. GNOME got the lock screen free inside gnome-shell;
# here it is one USE flag, and forgetting it means a laptop that cannot lock.
kde-plasma/kwin                   lock systemd screencast -gamepad -gles2-only -accessibility
# The session .desktop files. X? RDEPENDs kde-plasma/kwin-x11, i.e. a real X11 session —
# this flag, not kwin's, is what keeps the image Wayland-only.
kde-plasma/plasma-login-sessions  wayland -X
# REQUIRED_USE="fontconfig? ( X )" and both are default-on. X here pulls only X *libraries*
# (libX11/libICE/libSM/libXau/libxcb + xorg-proto) — no xorg-server — which is exactly plan/03's
# "X11 libraries remain, the Xorg server does not", so X stays on and the font-management KCM
# keeps working. semantic-desktop is kde-frameworks/baloo, the image's file indexer: ON in all
# three places below, and written positively even where it is already the default. See
# "File indexing" in section 2 for the runtime side.
kde-plasma/plasma-workspace       X fontconfig appstream networkmanager policykit systemd \
                                  ksysguard wallpaper-metadata semantic-desktop -telemetry
kde-plasma/plasma-desktop         semantic-desktop -webengine -ibus -scim -sdl
# There is no "packagekit" flag; the PackageKit backend is not built unless firmware/snap are.
# Flatpak backend only, exactly as gnome-software was.
kde-plasma/discover               flatpak -firmware -snap -telemetry -webengine
# brightness-control is DDC/CI for external monitors via app-misc/ddcutil — laptop backlight
# goes through logind either way, so this buys a package and no function we need.
kde-plasma/powerdevil             -brightness-control
kde-plasma/kscreen                -X
kde-plasma/print-manager          -gtk    # a GTK print dialog module; Flatpaks print via the portal
kde-apps/konsole                  -X
# semantic-desktop is the Information panel's tags/ratings/comments and content search in the
# Find bar; it is what pulls kde-apps/baloo-widgets. Unlike the two plasma packages above,
# dolphin's own IUSE has it OFF by default — only the profile global turns it on, which is
# exactly why it is spelled out here.
kde-apps/dolphin                  semantic-desktop -telemetry
# samba: kept deliberately for smb:// browsing in Dolphin. This is now the *only* thing holding
# net-fs/samba in the image, and through it dev-lang/perl + dev-perl/Parse-Yapp (unguarded
# COMMON_DEPEND). Setting -samba here is the one-flag escape hatch that removes all three.
# taglib: on, because kfilemetadata already pulls media-libs/taglib for the indexer (below).
# The flag buys audio tags in Dolphin's preview/tooltip path for a package that is now free.
kde-apps/kio-extras               samba -mtp -nfs -X taglib -openexr -ios

# The indexer's extractor set — the only real configuration surface Baloo has. exif and pdf
# arrive from the profile's global USE; the other four are off by default and are decided here.
# ffmpeg costs nothing: media-video/ffmpeg is already in the image, so it is free video/audio
# metadata. taglib is ~1 MB and covers a music library, which is the case file search is most
# often wanted for. epub pulls app-text/ebook-tools and mobi pulls
# kde-apps/kdegraphics-mobipocket — new packages for formats plan/03 sends to Flatpak readers.
kde-frameworks/kfilemetadata      exif pdf ffmpeg taglib -epub -mobi

# Replaces the GNOME-era "cairo" and "-qt6" lines. qt6 is required by kfilemetadata[pdf];
# cairo off because the cairo backend exists for poppler-glib, whose only consumer was
# localsearch. Nothing in a Plasma image links the glib frontend.
app-text/poppler                  qt6 -cairo
```

`systemsettings`, `breeze`, `breeze-gtk`, `kde-gtk-config`, `xdg-desktop-portal-kde`,
`plasma-systemmonitor`, `plasma-pa`, `bluedevil`, `kwallet-pam`, `polkit-kde-agent`,
`plasma-workspace-wallpapers`, `kde-frameworks/baloo` and `kde-apps/baloo-widgets` all have
empty `IUSE` — nothing to configure, and no line belongs in `package.use` for them. Baloo's
entire configuration surface is `kfilemetadata`'s six extractor flags above.

### `config/portage/package.mask/image` — the GNOME ban

Keep the existing `>=x11-drivers/nvidia-drivers-610` entry. Add a curated ban list. This is
belt-and-braces — `expected-packages.txt` remains the primary gate — but a mask fails the build
*at dependency resolution*, naming the package that pulled the offender, which is far easier to
act on than a 500-line diff at stage 50.

`mirror_target_pkg_config()` (`scripts/lib/common.sh:315`) copies `package.mask` onto the
builder's `/` as well, so these apply to both roots. That is fine now that `gnome-extra/tecla` is
gone from `@buildhost` — but it is the reason the list must stay curated rather than becoming
`gnome-base/*`.

```
# GNOME desktop components — this image is Plasma (plan/03, plan/09).
gnome-base/gnome-shell
gnome-base/gnome-session
gnome-base/gnome-settings-daemon
gnome-base/gnome-control-center
gnome-base/gnome-keyring
gnome-base/nautilus
gnome-base/gdm
gnome-base/gvfs
gnome-base/gnome-desktop
gnome-base/libgtop
gnome-extra/*
gui-apps/gnome-console
gui-libs/libadwaita
gui-libs/vte
dev-libs/gjs
x11-wm/mutter
x11-themes/gnome-backgrounds
sys-apps/xdg-desktop-portal-gnome
sys-apps/xdg-desktop-portal-gtk
# GNOME's file indexer. Baloo replaces it, so this bans a *duplicate* indexer, not indexing.
app-misc/localsearch
app-misc/tinysparql
app-arch/gnome-autoar
x11-misc/xdg-user-dirs-gtk
media-libs/libcanberra-gtk3
sci-geosciences/geocode-glib
app-admin/system-config-printer
# Browser engines: nothing native renders HTML here (plan/03). Structural, not flag-dependent.
net-libs/webkit-gtk
dev-qt/qtwebengine
```

`gnome-extra/*` covers gnome-software, gnome-system-monitor, evolution-data-server,
gnome-color-manager, nm-applet, polkit-gnome and tecla in one line. Deliberately **not** masked
— the allowed residue of §4: `gnome-base/librsvg`, `gnome-base/dconf`,
`gnome-base/gsettings-desktop-schemas`, `dev-libs/glib`, `net-libs/glib-networking`.

Also deliberately **not** masked: `net-fs/samba`. It is wanted, for `smb://` in Dolphin.
`app-admin/system-config-printer` stays banned — that was the GNOME printer UI, and nothing in
the Plasma set asks for it — so the mask still catches the cascade coming back the old way while
leaving the new, intentional holder alone.

### `config/portage/package.accept_keywords/image`

Remove `gnome-extra/gnome-software ~amd64` and `=dev-cpp/gtkmm-4.20.0-r1 ~amd64` (the gtkmm
`vulkan.pc` workaround existed for gnome-system-monitor). Keep the libva/nvidia entries.

Add exactly one entry. Every other package in the new `@desktop` is stable amd64 at the pinned
snapshot — Plasma `6.6.6`, Frameworks `6.27.0`, Gear `26.04.3`, `dev-qt/qtbase-6.11.1` — which is
verified, not assumed:

```
# The only ~amd64 package in the desktop set. Plasma Login Manager shipped with Plasma 6.6 and
# has no stable ebuild yet; x11-misc/sddm does, so this exception is the price of choosing PLM
# (plan/09). Pinned to =6.6.6 deliberately: -r1 and 6.7.4-r1 raise QTMIN to >=6.11.2, which is
# itself ~amd64 and would pull a ~amd64 Qt AND the ~amd64 Plasma 6.7.4 set in behind it. 6.6.6
# needs only QTMIN=6.10.0, satisfied by the stable qtbase-6.11.1.
# Drop the pin — not the entry — when 6.7.x stabilises alongside the rest of Plasma.
=kde-plasma/plasma-login-manager-6.6.6   ~amd64
```

If `emerge -p @desktop` reports any *other* masked-by-keyword package, that is new information:
add it here with the same one-line justification, and reconsider whether the set has drifted.

Nothing Baloo drags in needs an entry either: `kde-frameworks/baloo` and
`kde-frameworks/kfilemetadata` are stable at 6.27.0 with the rest of Frameworks,
`kde-apps/baloo-widgets` at 26.04.3 with the rest of Gear, and `dev-db/lmdb`, `media-libs/taglib`
and `media-gfx/exiv2` are all stable amd64 in the pinned snapshot.

### `config/portage/expected-packages.txt` — regenerate, do not hand-edit

The audit gate diffs the *entire* list; a desktop swap invalidates all 521 lines. Delete the
file, run the build, and stage 50 (`scripts/stages/50-prune.sh:78-81`) stops with
`out/reports/expected-packages.txt.generated` to review and commit. That is the documented
first-build flow — use it rather than trying to predict the KDE dependency closure by hand.

**Result: 615 lines**, committed 2026-08-25 with a header naming the allowed residue. The
audit that gates it is in §6.

---

## 2. Display manager, session, and boot hand-off

### Delete `config/rootfs/etc/gdm/custom.conf.in`

### Add `config/rootfs/etc/plasmalogin.conf.d/10-autologin.conf.in`

PLM reads drop-ins from `/etc/plasmalogin.conf.d/`; the Gentoo ebuild already ships
`01gentoo.conf` there (it blanks `InputMethod` to drop the qtvirtualkeyboard default), so a `10-`
prefix sorts after it. `install_rootfs_overlay()` renders `.in` and rebrands `distro` in
*basenames* only — directory names pass through — so this lands at
`/etc/plasmalogin.conf.d/10-autologin.conf`.

```ini
# Plasma Login Manager config for @DISTRO_NAME@ — v1 images double as live media (plan/01).
# /etc is an overlay, so this stays editable on a running machine.
[Autologin]
User=@LIVE_USER@
Session=plasma
Relogin=false
```

`Session=plasma` names `/usr/share/wayland-sessions/plasma.desktop`, installed by
`kde-plasma/plasma-login-sessions[wayland]`. PLM is a fork of SDDM and keeps its config syntax,
so `[Autologin] User=/Session=/Relogin=` should carry over unchanged — **confirm against
`man plasmalogin.conf` on the first build** and against `/usr/share/plasmalogin/` defaults, and
do not add `[General]`/`[Wayland]` compositor blocks unless they turn out to be needed: PLM
drives `kwin` itself, which is why it RDEPENDs `kwin[lock]`.

### Add `config/rootfs/usr/lib/systemd/system/plasmalogin.service.d/10-plymouth.conf`

```ini
[Unit]
# GDM had a plymouth USE flag: it conflicted with plymouth-quit.service and quit the splash
# itself with --retain-splash once the greeter had painted. Plasma Login Manager has no
# equivalent, so the splash is torn down by plymouth-quit.service as on the console-only image,
# and the login manager is ordered strictly after it — a deterministic hand-off rather than a
# race that shows up as a flash. Restoring a retain-splash hand-off is a plan/08 item.
After=plymouth-quit-wait.service
```

### `config/rootfs/usr/lib/systemd/system-preset/50-distro.preset.in`

`enable gdm.service` → `enable plasmalogin.service`. Fedora's rollout documents the unit as
`plasmalogin.service` and enables it with `systemctl enable --force`, which is the idiom for a
unit whose `[Install]` is `Alias=display-manager.service` — the same mechanism gdm used, so
nothing else in the preset flow changes. Stage 40's new assertion (§3) is what proves the alias
symlink actually got written.

### `config/rootfs/usr/lib/systemd/system/distro-boot-ok.service.in`

`ConditionPathExists=/usr/bin/gdm` → `/usr/bin/plasmalogin`. This also fixes a latent
inconsistency: `scripts/stages/30-target-rootfs.sh:120` documents gdm as living in `/usr/sbin`,
so the condition may never have matched at all.

The binary name is the one thing here not verified against an installed file list — it is
inferred from everything else the ebuild names (`/etc/plasmalogin.conf.d/`, `/run/plasmalogin`,
the `plasmalogin` user, and PAM stacks `plasmalogin`, `plasmalogin-greeter`,
`plasmalogin-autologin`). Stage 30's `have_exe plasmalogin` check (§3) searches `/usr/bin` and
`/usr/sbin` and fails the build loudly if it is wrong, which is where a wrong guess should
surface — not in `ConditionPathExists`, which fails *silently* by skipping the unit.

### KWallet needs no PAM edit

Gentoo's PLM ebuild installs its own PAM stacks, and both `plasmalogin` and
`plasmalogin-autologin` already carry:

```
-auth       optional    pam_kwallet5.so
-session    optional    pam_kwallet5.so auto_start
```

The leading `-` makes each line a no-op when the module is absent, so keeping
`kde-plasma/kwallet-pam` in `@desktop` is the whole of the work — auto-unlock comes for free.
(They carry matching `pam_gnome_keyring.so` lines too, inert here.) This removes the
`/etc/pam.d` edit that an SDDM-based plan would have needed in stage 40.

### `config/rootfs/usr/lib/systemd/system/multi-user.target.d/10-plymouth-quit.conf`

Body unchanged; rewrite the trailing comment. The `gdm[plymouth]` carve-out is gone —
`plymouth-quit.service` now tears the splash down on **both** the desktop and console-only
images, which makes this drop-in load-bearing everywhere rather than *"harmless on the desktop
image"*.

### `config/branding/distro.script.in`

The `on_quit()` comment (~line 143) explains the resting-opacity choice in terms of gdm's
`--retain-splash`. The reasoning (leave the mark fully lit rather than mid-cycle) still holds;
retarget the wording at plymouth-quit / Plasma Login Manager. No code change.

### `config/rootfs/etc/polkit-1/rules.d/49-wheel.rules`

Comment: "GNOME Software" → "Discover".

### File indexing: add `config/rootfs/etc/xdg/baloofilerc`

`semantic-desktop` (§1) puts `baloo_file` in every user session. Four packages arrive with it —
`kde-frameworks/baloo`, `kde-frameworks/kfilemetadata`, `kde-apps/baloo-widgets` and
`dev-db/lmdb` (the index store; stable amd64, no keyword entry needed). **None of them belongs
in `@desktop`:** plasma-workspace and plasma-desktop pull baloo, dolphin pulls baloo-widgets,
baloo pulls kfilemetadata and lmdb. Listing them in the set would only invite version pins the
set does not own.

This is not a new capability for the distro, and the plan should not present it as one. The
GNOME image indexes too: `app-misc/localsearch` and `app-misc/tinysparql` are both in today's
`expected-packages.txt`, and `app-text/poppler[cairo]` is kept at `package.use/image:165`
specifically so `localsearch[pdf]` can read PDFs. Baloo is that same feature under the new
desktop — which is why the localsearch/tinysparql mask entries in §1 are a ban on duplicate
function rather than a statement that this image does not index.

**The index lives in `/var`.** `$HOME` is `/var/home/<user>` (`tmpfiles.d/distro-state.conf.in`),
so `~/.local/share/baloo/index` sits on the growable var partition — which `repart.d/50-var.conf`
extends to the end of the disk at first boot — and never on the read-only erofs root. Nothing in
the immutable layout constrains it. A factory reset (wipe `var`, plan/01:150) drops the index
along with the home directory it describes, which is correct and is worth one line in plan/05 so
it is not later reported as data loss.

Ship the defaults **system-wide, not through a skel copy**. KConfig cascades `$XDG_CONFIG_DIRS`
(`/etc/xdg`) underneath `~/.config`, so `/etc/xdg/baloofilerc` is the image's default layer and
anything the user changes in System Settings → Search is written to `~/.config/baloofilerc` and
wins. `/etc` is the overlayfs backed by `/var/overlay/etc`, so the file stays editable on a live
system. `install_rootfs_overlay()` copies any non-`.in` file verbatim at 0644
(`scripts/lib/common.sh:134`), so this needs no templating and no stage-40 change — and
`tests/test-overlay-install.sh` picks it up with the rest of the tree.

```ini
# Image defaults — the /etc/xdg layer. ~/.config/baloofilerc overrides anything here.
[Basic Settings]
Indexing-Enabled=true

[General]
# Index file names and metadata, NOT file contents. Content extraction is what makes the index
# large and the first-login I/O heavy; names, tags and the EXIF/ID3/PDF metadata that
# kfilemetadata's extractors provide are what Dolphin's Find bar and the KRunner file runner
# actually use. A user who wants full-text ticks one box in System Settings and re-indexes into
# their own baloofilerc.
only basic indexing=true

# The Flatpak per-app data tree. Baloo skips dotted paths already, so this is belt-and-braces:
# the preinstalled Firefox Flatpak alone would otherwise be a browser cache sitting in the
# index the day someone turns content indexing on.
exclude folders[$e]=$HOME/.var/
```

---

## 3. Stage scripts

### `scripts/stages/30-target-rootfs.sh`

- Verify block (125-128): `have_exe gdm` → `have_exe plasmalogin`; `have_exe gnome-shell` →
  `have_exe plasmashell`. **Add** `have_exe kwin_wayland` — a Plasma image whose compositor is
  missing boots to a greeter and nothing else, and PLM uses kwin as its greeter compositor, so
  it is load-bearing twice over.
- The comments at lines 30 and 46 use `gdm[-X]` and `net-libs/webkit-gtk` as their worked
  examples; retarget them (`kwin[-X]`, `dev-qt/qtwebengine`) so the guards' documentation stays
  true.

### `scripts/stages/40-configure.sh`

- Finalizers (162-165): keep `glib-compile-schemas` (GTK apps and several KDE components ship
  GSettings schemas), keep `fc-cache`, `update-desktop-database`, `update-mime-database`.
- **New assertions** in the verify block, in the house style — each is a failure that would
  otherwise surface only as a black screen:

  ```bash
  [[ -f $TARGET/usr/share/wayland-sessions/plasma.desktop ]] \
    || die "verify: /etc/plasmalogin.conf.d names Session=plasma but no plasma.desktop wayland
  session exists — is kde-plasma/plasma-login-sessions[wayland] installed?"
  compgen -G "$TARGET/etc/systemd/system/display-manager.service" >/dev/null \
    || die "verify: plasmalogin.service not enabled (preset did not take)"
  compgen -G "$TARGET/usr/lib64/security/pam_kwallet"*.so >/dev/null \
    || warn "verify: no pam_kwallet module — KWallet will prompt instead of auto-unlocking"
  ```

  The `plasmalogin` binary itself is asserted in stage 30 (`have_exe`), not here — that is the
  earliest stage where its absence can be attributed to the emerge rather than to this stage.

### `scripts/stages/50-prune.sh`

- **Delete the VTE demo block** (144-154) and its assertions (267-271). `gui-libs/vte` goes with
  gnome-console.
- **Replace with Plasma presence assertions:**

  ```bash
  [[ -x $T/usr/bin/konsole ]]             || violation "konsole missing after prune"
  [[ -x $T/usr/bin/dolphin ]]             || violation "dolphin missing after prune"
  [[ -x $T/usr/bin/plasmashell ]]         || violation "plasmashell missing after prune"
  [[ -x $T/usr/bin/startplasma-wayland ]] || violation "startplasma-wayland missing after prune"
  [[ -x $T/usr/bin/plasmalogin ]]         || violation "plasma-login-manager missing after prune — no way to log in"
  [[ -f $T/usr/share/wayland-sessions/plasma.desktop ]] \
                                          || violation "plasma.desktop wayland session missing after prune"
  [[ -x $T/usr/bin/balooctl6 ]]           || violation "balooctl6 missing after prune — semantic-desktop did not take"
  ```

  The `balooctl6` line is the cheapest assertion that `semantic-desktop` actually resolved: the
  flag is a profile global, so a profile change or a stray `-semantic-desktop` would silently
  produce a Plasma image with no indexer and no error anywhere else. Confirm the binary's name
  and path against the first build's file list before trusting it — see the open items.

- **Prune dirs** (138-142): `usr/share/help` (yelp) can go — nothing installs there now; keep the
  line as a cheap guard and retarget its comment at KDE handbooks (`/usr/share/doc/HTML`,
  already covered by the existing `usr/share/doc` entry, which `-handbook` should leave empty in
  the first place).
- **`usr/lib64/girepository-1.0`**: the current comment says these typelibs are *deliberately
  kept* for gjs/gnome-shell. With `-introspection` global they should not be built at all — add
  the directory to the deletion list as a guard, and rewrite the comment to record why the
  exception was withdrawn.
- **Interpreter policy comment** (332-344): rewrite, but only half of it. `dev-lang/python` was
  admitted because gnome-shell folds DEPEND into RDEPEND — that chain is gone. `dev-lang/perl` +
  `dev-perl/Parse-Yapp` came in behind `net-fs/samba`, and samba stays; only its holder changes,
  from `gnome-control-center[cups]` to `kde-apps/kio-extras[samba]`. So the perl allowance
  survives as-is and needs its chain re-cited, not deleted — the same edit applies at `:44`,
  where that justification is repeated, and at `:343-344`, where the assertion whitelist spells
  it out. Do **not** pre-emptively ban python — let the first build's
  `expected-packages.txt.generated` say what actually arrives, then record the surviving
  allowlist *with its chain*, the way the current comment does. The `dev-python/*` and
  `app-admin/perl-cleaner` / `sys-apps/portage` unmerge loop (48-59) is already guarded by
  existence checks and needs no change.

### `scripts/stages/70-test.sh`

No change. It asserts `graphical.target` reached, `failed_units=0`, resolved active — all
desktop-agnostic, as is the in-guest reporter
(`config/rootfs/usr/lib/image-test/test-report.sh.in`).

### `tests/`

No GNOME assertions exist. `tests/test-overlay-install.sh` renders the whole overlay tree, so it
picks up the new `plasmalogin.conf.d` and `plasmalogin.service.d` files automatically — confirm it
still passes
after the rename.

---

## 4. `builder/Dockerfile` and the allowed residue

Lines 81-101 mirror target `package.use` onto the builder's `/` so portage's depgraph does not
produce phantom slot conflicts and REQUIRED_USE failures (the long note at 59-71 explains why).
Replace the GNOME lines with Plasma equivalents — `discover`, `kwin lock`, `plasma-workspace`,
`polkit kde -gtk`, `appstream qt6`, `libportal qt6` — and drop `gdm`, `gnome-software`,
`gnome-control-center`, `evolution-data-server`, `mutter`, `gcr gtk`, `libcanberra -udev`.

**Keep:** `gnome-base/librsvg tools` and the `gnome-base/librsvg` entry in the emerge list at
line 115 (rsvg-convert rasterises the splash SVGs; build-only, never in the image),
`media-fonts/ibm-plex`, `dev-python/pillow`, and every gtk/glib/cairo line — the GTK bridge still
needs them.

Note for whoever does this: `mirror_target_pkg_config()` writes `zz-target-mirror`, which sorts
after the Dockerfile's `builder` file and wins on conflict, so these lines are largely redundant
with the runtime mirror. They matter for the builder's *own* emerge inside the Dockerfile, and as
documentation. Existing drift (lines 81/85/89 already disagree with `package.use/image`) is worth
eliminating while rewriting rather than reproducing.

### Allowed residue

The GNOME-project packages that legitimately remain in the image. The new
`expected-packages.txt` should carry these with a comment saying why:

| Package | Held by |
|---|---|
| `dev-libs/glib` | flatpak, NetworkManager, polkit, pipewire — desktop-independent |
| `net-libs/glib-networking` | glib's TLS backend; flatpak's HTTP path |
| `x11-libs/gtk+` (GTK **3** only), `x11-libs/gdk-pixbuf`, `x11-libs/pango` | `kde-gtk-config` DEPENDs `x11-libs/gtk+:3[X]`. **Not `gui-libs/gtk`** — see item 7 in "What the plan got wrong"; GTK 4 leaves the image, confirmed absent from the built allowlist |
| `x11-themes/adwaita-icon-theme` (+ `-legacy`) | hard RDEPEND of GTK 3 |
| `x11-misc/xsettingsd` | RDEPEND of `kde-gtk-config` — not GNOME-namespace, but part of the same bridge |
| `gnome-base/librsvg` | RDEPEND of adwaita-icon-theme (SVG icon loading) |
| `gnome-base/dconf`, `gnome-base/gsettings-desktop-schemas` | GSettings backend + schemas the GTK bridge reads |

Everything else in the `gnome-*` space should be absent, and the mask list in §1 makes that
structural.

---

## 5. Documentation to update

Mechanical but non-trivial — nine files assert GNOME as a design fact:

| File | What changes |
|---|---|
| `README.md:3` | "minimal-GNOME" → "minimal-KDE-Plasma" |
| `plan/03-package-set.md` | The largest rewrite: Strategy (profile, global USE — the "X11 libraries stay, Xorg server goes" paragraph is still correct), the `@desktop` table (replace wholesale), "Dropped from the native set" (keep the file-roller / gnome-text-editor history as background, add the KDE equivalents Ark/Kate with the same reasoning), the portals paragraph (portal-kde), plus a new subsection recording the ban list and allowed residue from §4, and one recording file indexing: Baloo replaces localsearch/tinysparql, `only basic indexing` is a deliberate default rather than an accident, and the extractor set is a stated choice |
| `plan/00-overview.md:8,25,71` | M2 "GNOME Wayland session via GDM autologin" → Plasma session via Plasma Login Manager autologin; GNOME Software → Discover |
| `plan/01-architecture.md:74,157-158` | Boot flow `graphical.target → GDM → GNOME Shell`, and the autologin rationale |
| `plan/02-build-pipeline.md:35,83,135,154,162,166,172,177,209,211` | Overlay file name, `polkit[gtk]` → `polkit[kde]`, profile string, stage-30 verify names, preset list, and the "GNOME from source dominates" build-time estimate — Qt6 + Frameworks + Plasma is comparable or larger; say so |
| `plan/04-image-and-boot.md:70,109,119,142` | Splash → Plasma Login Manager hand-off |
| `plan/05-updates.md:118-119` | GNOME Software → Discover shows Flatpak updates; **add** a line that a factory reset drops `~/.local/share/baloo/index` with the rest of `/var` and the desktop silently re-indexes — expected, not data loss |
| `plan/06-pruning.md` | The typelib exception (`:20,30`); the xdg-utils/cups/samba cascade (`:110-122`) — item 1 (`xdg-utils[perl]`) stands unchanged, item 2 (samba → perl) is rewritten rather than deleted: the dependency fact is still true, the holder is now `kio-extras[samba]`, and the escape hatch at `:124` changes from "set `gnome-control-center -cups`" to "set `kio-extras -samba`", which drops samba and perl but costs `smb://` in Dolphin; the "Python under GNOME — RESOLVED" section (`:132-164`) whose entire dependency chain no longer exists, the Qt6/Xorg section (`:202-206`) which now reads the other way round — and note that `poppler -qt6` does not merely become harmless but inverts outright, since `kfilemetadata[pdf]` *requires* `poppler[qt6]`; and the size-budget row (`:255`, "GNOME Shell + GTK4 + Mutter (no webkit) = 1.6 GiB") — replace with a measured figure after the first build |
| `plan/07-testing.md:88-89` | NVIDIA Wayland session checks; Flatpak install via Discover |
| `plan/08-roadmap.md:11-18,41-42,69,76-78,87` | The installer would now be Qt/Kirigami, not GTK4/libadwaita; open question 4 (GDM Wayland on NVIDIA) becomes Plasma Login Manager, whose greeter is kwin — so the NVIDIA Wayland question is now the *session* question, not a separate one; **add** the retain-splash hand-off as a new roadmap item |

---

## 6. Build and verification

The profile change invalidates the existing target root — stage 30's staleness guard
(`scripts/stages/30-target-rootfs.sh:36-41`) will refuse to run against it, correctly. Start
clean. The binpkg cache volume is kept, but the official binhost's packages were built against
the *default* profile's USE, so most of Qt6 / Frameworks / Plasma will compile from source:
**budget several hours**, more than the GNOME build took.

```sh
bash tests/run-tests.sh                        # offline: syntax, CRLF, config lint, unit tests
bash scripts/build.sh --dry-run                # stage wiring
bash scripts/build.sh --clean --console-only   # fast check that @base/@hardware still resolve
bash scripts/build.sh --clean                  # the real build
# stage 50 stops here on the first run:
#   review out/reports/expected-packages.txt.generated  <- CHECK ITS MTIME FIRST
cp out/reports/expected-packages.txt.generated config/portage/expected-packages.txt
bash scripts/build.sh --from 50
```

> **`out/` is never cleaned between runs.** Stale reports from previous builds sit there until a
> stage overwrites them, and stage 50 writes `expected-packages.txt.generated` only when it
> reaches its audit gate. During this migration a report from the *first GNOME build* (four days
> stale, still listing `gdm`, `nautilus`, `xorg-server` and `xf86-video-*`) was very nearly
> committed as the Plasma allowlist. `stat -c %y` the file and confirm it is newer than the
> stage-30 completion before copying it. The same trap applies to `size-report.txt`, which is
> written *after* the gate and therefore does not exist yet when the gate first stops the build.

**Outcome, 2026-08-25.** All of the above ran. Notes from doing it:

- The build must start from stage 20, not 30, whenever `config/portage` or `build.conf` has
  changed since the config root was assembled — stage 30's first guard says so itself. Do not
  compute `portage_config_hash` on the host to check: it runs `sha256sum` over
  `find "$REPO/config/portage"`, and `sha256sum` embeds the **absolute path**, so a host-side
  value (`/home/…/repo`) can never equal the container's (`/repo`). Compare inside the builder
  or not at all.
- Never run two stages concurrently against the same work volume. Two `30-target-rootfs.sh`
  containers were briefly live at once, both emerging into the same `$TARGET` and both appending
  to the same log; the only safe recovery was `docker volume rm immos-work` and a restart.
- `UPDATE_VERIFY=1` in `build.conf` with no `config/keys/import-pubring.gpg` stops stage 40 dead.
  Dev builds need `UPDATE_VERIFY=0` (or `UPDATE_VERIFY_OVERRIDE=0` in the environment).

Then, in order:

1. **Audit the generated allowlist before committing it.** This is the gate that makes "minimal"
   true, so read it rather than pasting it:

   ```sh
   grep -iE 'gnome|gdm|mutter|nautilus|gjs|adwaita|webkit|qtwebengine' \
     config/portage/expected-packages.txt
   wc -l config/portage/expected-packages.txt   # compare against GNOME's 521
   ```

   Everything the first command returns must be in the §4 residue table. Anything else means a
   mask is missing or a USE flag is wrong.

   **Done. It returns exactly five names** — `gnome-base/{dconf,gsettings-desktop-schemas,librsvg}`
   and `x11-themes/adwaita-icon-theme{,-legacy}` — all of them in the residue table. No ruby, no
   `gui-libs/gtk`, no `xorg-server`, no `xf86-*`. 615 entries against GNOME's 521: +94, of which
   128 are `kde-*` (115) and `dev-qt/*` (13), so the non-desktop set actually *shrank*.

2. **Size.** `out/reports/size-report.txt` — **done**, and folded into plan/06's "Measured: the
   first Plasma build" section. Headline: +688 MiB installed (7674 → 8362), +496 MiB EROFS
   (2884 → 3381), +412 MiB on the A/B update payload (2107 → 2519). Concentrated almost entirely
   in `usr/lib64` (+365, Qt6/Frameworks) and `usr/share/icons` (+135, breeze-icons).

3. **Stage 70 smoke** runs automatically: two boots, `graphical.target` reached,
   `failed_units=0`, machine-id persists, resolved active.

4. **Manual QEMU pass** — the things no automated test can see (stage 70 reads a serial port, so
   an image that boots to a black screen still passes it):

   ```sh
   bash scripts/run-vm.sh out/immos-0.2.0.img
   ```

   - splash appears, then Plasma Login Manager autologins straight into a Plasma **Wayland**
     session (`echo $XDG_SESSION_TYPE` → `wayland`), and `systemctl status plasmalogin` is
     active;
   - the screen locks (`loginctl lock-session`) — that is `kwin[lock]` doing its job, and it is
     the flag most likely to be dropped by accident;
   - Konsole and Dolphin launch; Discover lists Flathub and can install an app;
   - **Baloo runs and stays basic.** `balooctl6 status` reports the indexer running with a file
     count that grows and then settles; `~/.local/share/baloo/index` exists under `/var/home`;
     typing a filename into Dolphin's Find bar or KRunner returns it. Then confirm the default
     took: `grep -r "only basic indexing" ~/.config/baloofilerc /etc/xdg/baloofilerc` and check
     `balooctl6 indexSize` against a home with a few hundred files. If the index is large, the
     `/etc/xdg` key name is wrong and content indexing is on — see the open items;
   - Dolphin's Network view opens `smb://` and can reach a share — that is `kio-extras[samba]`,
     the one flag this image pays a perl interpreter for, so it is worth confirming it works;
   - the preinstalled Firefox Flatpak launches, its file picker opens (that is
     xdg-desktop-portal-kde doing its job), and it picks up the Breeze GTK theme;
   - System Settings opens the Network / Audio / Power / Display / Bluetooth / Printers panels;
   - a polkit prompt appears when Discover installs system-wide (polkit-kde-agent);
   - KWallet either auto-unlocks (pam_kwallet took) or prompts once — either is acceptable, but
     note which, for the docs.

5. **Update E2E** (`UPDATE_TEST_BASE_IMG=<old.img>`) is unaffected by the desktop swap but is
   worth one run: the version being updated *from* is a GNOME image, so it exercises exactly the
   "whole rootfs replaced" path this change makes maximal.

---

## What the plan got wrong

Recorded rather than quietly fixed, because each one is a class of mistake worth recognising
next time.

**1. `media-libs/libcanberra` was listed for deletion. It is more firmly in a Plasma image than
it ever was in a GNOME one** — an unconditional dependency of `kde-plasma/kwin`,
`plasma-desktop`, `plasma-pa` **and** `plasma-workspace`. Its `-udev` line stays in both
`package.use/image` and `builder/Dockerfile`, and the Dockerfile's reason for it (a phantom
`REQUIRED_USE="udev? ( alsa )"` failure evaluated against the builder's alsa-less `/`) is
unchanged. The mistake was reasoning from "it was in the GNOME block" instead of from RDEPEND.

**2. Backslash line continuations in `package.use` do not work.** The plan's
`plasma-workspace` entry was written across two lines with a trailing `\`. Portage's
`grabfile()` does no continuation handling whatsoever (`portage/util/__init__.py`) — the `\`
would have been parsed as a literal USE token. Repeating the atom on a second line is the
correct idiom and is what the file already did for `app-text/poppler`.

**3. `-introspection` as a *global* flag needed `-vala` beside it.** "Dropped from the global
set" was not enough: most packages that build typelibs default `introspection` on in their own
`IUSE`, so the token has to be negated, and once negated, `gnome-base/librsvg` and
`app-crypt/libsecret` both fail `REQUIRED_USE="vala? ( introspection )"`. `-vala` globally is
the right answer independently — stage 50 deletes `usr/share/vala` wholesale.

**4. The Qt module family has to be flag-matched by hand, per package.** `dev-qt/*` modules
bind each other with mirrored USE-deps (`~dev-qt/qtbase[opengl=,vulkan=,icu=,...]`), and
portage evaluates those against the **builder's own `/`**, where the target's global USE does
not apply — the multi-root quirk already documented at length in `builder/Dockerfile`. So
`opengl`, `vulkan`, `qml`, `dbus` and `X` all had to be restated per-package even though every
one of them is already on globally. Eight lines, all of them mirror artefacts rather than
choices: `qtbase`, `qtdeclarative`, `qt5compat`, `qttools`, `qtmultimedia`, `qtquick3d`, plus
`kconfig`/`kcoreaddons`/`kguiaddons`/`kidletime`/`kimageformats`/`kwindowsystem`/`prison`/
`sonnet`, `qcoro`, `dbus`, `avahi`, `libva` and `wpa_supplicant`.

**5. `kde-frameworks/sonnet[hunspell]` brings back the exact dependency tail plan/03 dropped
gnome-text-editor to avoid** — and worse, it *fails the depgraph outright*, because this image's
`L10N` uses plain `en` while `app-dicts/myspell-en`'s `REQUIRED_USE` demands one of
`en-AU/en-CA/en-GB/en-US/en-ZA`. Fixed with `sonnet[-hunspell,-aspell]`.

**6. `x11-misc/xdg-user-dirs[gtk]` pulls the masked `xdg-user-dirs-gtk`.** Caught by the new
mask, at dependency resolution, naming the puller — which is precisely the argument this plan
made for adding the mask in the first place. Fixed with `xdg-user-dirs -gtk`.

**7. The GTK bridge holds GTK *3*, not GTK 4.** `kde-gtk-config` DEPENDs `x11-libs/gtk+:3[X]`;
`breeze-gtk` is a pure theme with no runtime GTK dependency at all. So `gui-libs/gtk` leaves
the image (confirmed by the depgraph), and the §4 residue table was wrong to list it. GTK3 is
what keeps `adwaita-icon-theme` → `librsvg` in, so the residue itself is unchanged in shape.
`x11-misc/xsettingsd` is a new arrival, via `kde-gtk-config`'s RDEPEND.

**8. Two package.use lines are now dead.** `dev-libs/libportal` (not in the Plasma graph at
all) and `sys-libs/minizip-ng`. **Confirmed by the build** — neither package is in the 615-entry
allowlist. They are kept as documented no-ops rather than deleted: a line for an absent package
costs nothing, and if a later portal or flatpak change does pull libportal back, it should
arrive with the Qt binding rather than the GTK one. Delete them if that stops being true.
`gui-libs/gtk`'s line is in the same position for the same reason (see item 7).

**9. `app-crypt/libsecret` arrives via KWallet** — `kio[kwallet]` → `kwallet` →
`kwallet-runtime` → `libsecret`. That answers one of the open questions below about
`org.freedesktop.secrets` for Flatpak apps: the Secret Service bridge comes with KWallet rather
than needing a separate package.

**10. `net-dns/avahi[mdnsresponder-compat]` is required by `kde-frameworks/kdnssd`,** which is
how `kio-extras` advertises and browses network services — the same feature `smb://` is kept
for. A real choice, not a mirror artefact.

**11. Stage 50's desktop presence assertions had to become conditional on `CONSOLE_ONLY`.**
The GNOME ones (`gnome-console`, `libvte`) were unconditional, which means a `--console-only`
build was flagging prune violations for packages it was never supposed to have. Fixed while
replacing them.

## Settled against the pinned tree

These were open questions in the first draft; they are answered and folded into the sections
above.

- **IUSE for every `kde-plasma/*` package** — read from the 6.6.6 ebuilds. The corrections that
  mattered: `discover` has no `packagekit` flag; `powerdevil` has no `powerprofiles` flag
  (`brightness-control` is DDC/CI via ddcutil); `kwin` has no `X` flag at all — the X11
  compositor is a separate `kde-plasma/kwin-x11` package; and eleven of the packages have empty
  `IUSE` and need no line.
- **`kwin[lock]`** — not default-on, required by `plasma-login-manager`, and the only thing that
  puts `kscreenlocker` in the image. Confirmed present in the resolved set.
- **`plasma-workspace` REQUIRED_USE `fontconfig? ( X )`** — and its `X?` block pulls only X
  libraries, never `xorg-server`, so `X` stays on. Note `plasma-workspace` also RDEPENDs
  `x11-apps/{xmessage,xprop,xrdb}` unconditionally; none of them pulls a server either, and
  `xrdb-1.2.2` is stable amd64 so no keyword entry is needed.
- **Keywords** — everything is stable amd64 at Plasma 6.6.6 / Frameworks 6.27.0 / Gear 26.04.3
  except `kde-plasma/plasma-login-manager`. One `package.accept_keywords` entry, pinned to
  `=6.6.6`; the resolved graph confirms nothing else `~amd64` comes in behind it.
- **`semantic-desktop` is a profile global**, not a per-package default:
  `profiles/targets/desktop/plasma/make.defaults` sets it. `plasma-workspace` and
  `plasma-desktop` carry `+semantic-desktop` in their own `IUSE` too; `kde-apps/dolphin` does
  **not**, and gets it only from the profile. All three are written positively so the image
  keeps its indexer if the profile ever drops the token.
- **`kde-frameworks/baloo` and `kde-apps/baloo-widgets` have empty `IUSE`**, and
  `kde-frameworks/kfilemetadata` has `epub exif ffmpeg mobi pdf taglib` — the whole of the
  indexer's build-time configuration.
- **`kde-plasma/print-manager`**, not `kde-apps/`.
- **KWallet auto-unlock** — Gentoo's PLM PAM stacks already carry the `pam_kwallet5.so` lines,
  so no stage-40 `/etc/pam.d` edit is needed.
- **PLM's binary and paths** — the ebuild sets `-DRUNTIME_DIR=/run/plasmalogin`, installs
  `/etc/plasmalogin.conf.d/01gentoo.conf`, and adds PAM stacks `plasmalogin`,
  `plasmalogin-greeter`, `plasmalogin-autologin`. The binary *name* is still inferred (see
  below).

## Settled by the first build (2026-08-25)

- **The `plasmalogin` binary path** — it is `/usr/bin/plasmalogin`. The inference from the
  ebuild's other paths was right, which means `distro-boot-ok.service`'s
  `ConditionPathExists=/usr/bin/plasmalogin` matches and the boot-success gate is live rather
  than silently skipped.
- **`balooctl6`** — that is the installed name; plain `balooctl` does not exist. Stage 50's
  assertion accepts both, deliberately: it exists to catch a missing indexer, not to pin a
  filename, and a future KF rename should trip it loudly.
- **The `~amd64` blast radius** — three unstable packages in the built image and no more:
  `plasma-login-manager-6.6.6`, `nvidia-drivers`, `libva-intel-media-driver`. The `=6.6.6` pin
  held; nothing dragged a `~amd64` Qt or Plasma 6.7.4 in behind it.
- **`@buildhost` needed no entry.** No tecla-shaped configure-time RDEPEND surfaced; the set is
  still empty and its header still explains what to watch for.
- **`kwin[lock]` took** — `kde-plasma/kscreenlocker` is in the image. Whether the lock screen
  actually *engages* is a manual-pass question, not a package one.
- **Size** — measured; see plan/06.
- **Python** — resolved, and the chain is `power-profiles-daemon → switcheroo-control →
  pygobject → pycairo`, i.e. not the desktop's doing at all. Full table in plan/06.

## Open items — the manual QEMU pass decides

None of these is answerable from a build log. Stage 70 reads a serial port, so an image that
boots to a black screen still reports green.

- **PLM's autologin config keys.** Assumed SDDM-compatible (`[Autologin] User/Session/Relogin`)
  because PLM is a fork. The build proves the file is *installed*, not that PLM *reads* it —
  confirm against `man plasmalogin.conf` and `/usr/share/plasmalogin/`, and by observing whether
  the greeter actually logs in without a password.
- **The `baloofilerc` key spellings.** `[Basic Settings] Indexing-Enabled`, `[General] only basic
  indexing` and `[General] exclude folders[$e]` are written from Baloo's documented config, not
  read off an installed file. A wrong key is *silently ignored*, and the failure mode is full
  content indexing with no error anywhere — so verify by flipping the matching switch in
  System Settings → Search and diffing the resulting `~/.config/baloofilerc` against the
  `/etc/xdg` copy.
- **Whether `baloo_file` autostarts** from `/etc/xdg/autostart/` or a systemd user unit under
  KF6, and whether the index lands under `/var/home` as intended.
- **Whether `-introspection` global holds at runtime.** The graph resolves and the image builds;
  whether some surviving package dlopens a typelib it no longer has is a different question, and
  the rollback (put `introspection` back globally *and* restore the `girepository-1.0` prune) is
  documented in plan/06.
- **Whether PLM's `pkg_setup` kernel check (`CONFIG_CHECK="~DRM"`) was quiet.** It did not fail
  the build, which is all that is known; the `~` prefix means a warning would have passed
  unnoticed in a 14 MB emerge log.

## Known issue, not caused by this migration

**`systemd-repart` fails in the initrd on every boot** — `Failed to start Repartition Root Disk`,
on both stage-70 smoke boots. It does not appear in `systemctl --failed` afterwards because the
failure is in the initrd instance, which is why `failed_units=0` is not a contradiction.

The cause is geometry, not the desktop: `ESP 1024 + 2×root 6144 + var 4096 = 17408 MiB` against
a 17410 MiB image, so repart has ~2 MiB to grow `var` into and gives up. `var_size` in the guest
report is 4143677440 bytes — the built size, ungrown. In a VM whose disk is exactly the image
that is arguably correct behaviour; on real hardware with a larger disk it is the mechanism
plan/01 relies on for "var grows to fill the disk", and **nothing has ever exercised it**.
Worth a run against an over-provisioned disk before trusting that guarantee.
