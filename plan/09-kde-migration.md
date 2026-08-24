# 09 — KDE Plasma Migration

**Status: proposed, not started.** This document is the working plan for replacing the GNOME
desktop with a minimal KDE Plasma 6 one. It is written to be iterated on before any code
changes; once executed, its content folds back into plan/03 (package set) and plan/06 (pruning)
and this file becomes history.

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
`app-text/poppler` (both lines), and the printer-panel cascade `media-libs/tiff` /
`net-fs/samba` / `net-libs/ngtcp2` — that cascade existed only because
`gnome-control-center[cups]` pulled `app-admin/system-config-printer` → samba.
`kde-plasma/print-manager` talks to CUPS directly.

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
# keeps working. semantic-desktop pulls kde-frameworks/baloo: no file indexer in this image.
kde-plasma/plasma-workspace       X fontconfig appstream networkmanager policykit systemd \
                                  ksysguard wallpaper-metadata -semantic-desktop -telemetry
kde-plasma/plasma-desktop         -semantic-desktop -webengine -ibus -scim -sdl
# There is no "packagekit" flag; the PackageKit backend is not built unless firmware/snap are.
# Flatpak backend only, exactly as gnome-software was.
kde-plasma/discover               flatpak -firmware -snap -telemetry -webengine
# brightness-control is DDC/CI for external monitors via app-misc/ddcutil — laptop backlight
# goes through logind either way, so this buys a package and no function we need.
kde-plasma/powerdevil             -brightness-control
kde-plasma/kscreen                -X
kde-plasma/print-manager          -gtk    # a GTK print dialog module; Flatpaks print via the portal
kde-apps/konsole                  -X
kde-apps/dolphin                  -semantic-desktop -telemetry
# samba must not come back through the side door after the printer-panel cascade removed it.
kde-apps/kio-extras               -samba -mtp -nfs -X -taglib -openexr -ios
```

`systemsettings`, `breeze`, `breeze-gtk`, `kde-gtk-config`, `xdg-desktop-portal-kde`,
`plasma-systemmonitor`, `plasma-pa`, `bluedevil`, `kwallet-pam`, `polkit-kde-agent` and
`plasma-workspace-wallpapers` all have empty `IUSE` — nothing to configure, and no line belongs
in `package.use` for them.

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
app-misc/localsearch
app-misc/tinysparql
app-arch/gnome-autoar
x11-misc/xdg-user-dirs-gtk
media-libs/libcanberra-gtk3
sci-geosciences/geocode-glib
app-admin/system-config-printer
net-fs/samba
# Browser engines: nothing native renders HTML here (plan/03). Structural, not flag-dependent.
net-libs/webkit-gtk
dev-qt/qtwebengine
```

`gnome-extra/*` covers gnome-software, gnome-system-monitor, evolution-data-server,
gnome-color-manager, nm-applet, polkit-gnome and tecla in one line. Deliberately **not** masked
— the allowed residue of §4: `gnome-base/librsvg`, `gnome-base/dconf`,
`gnome-base/gsettings-desktop-schemas`, `dev-libs/glib`, `net-libs/glib-networking`.

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

### `config/portage/expected-packages.txt` — regenerate, do not hand-edit

The audit gate diffs the *entire* list; a desktop swap invalidates all 521 lines. Delete the
file, run the build, and stage 50 (`scripts/stages/50-prune.sh:78-81`) stops with
`out/reports/expected-packages.txt.generated` to review and commit. That is the documented
first-build flow — use it rather than trying to predict the KDE dependency closure by hand.

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
  ```

- **Prune dirs** (138-142): `usr/share/help` (yelp) can go — nothing installs there now; keep the
  line as a cheap guard and retarget its comment at KDE handbooks (`/usr/share/doc/HTML`,
  already covered by the existing `usr/share/doc` entry, which `-handbook` should leave empty in
  the first place).
- **`usr/lib64/girepository-1.0`**: the current comment says these typelibs are *deliberately
  kept* for gjs/gnome-shell. With `-introspection` global they should not be built at all — add
  the directory to the deletion list as a guard, and rewrite the comment to record why the
  exception was withdrawn.
- **Interpreter policy comment** (332-344): rewrite. `dev-lang/python` was admitted because
  gnome-shell folds DEPEND into RDEPEND; `dev-lang/perl` + `dev-perl/Parse-Yapp` because
  `net-fs/samba` was a hard dep of `gnome-control-center[cups]`. Both chains are gone. Do **not**
  pre-emptively ban either — let the first build's `expected-packages.txt.generated` say what
  actually arrives, then record the surviving allowlist *with its chain*, the way the current
  comment does. The `dev-python/*` and `app-admin/perl-cleaner` / `sys-apps/portage` unmerge loop
  (48-59) is already guarded by existence checks and needs no change.

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
| `gui-libs/gtk`, `x11-libs/gtk+`, `x11-libs/gdk-pixbuf`, `x11-libs/pango` | the `breeze-gtk` / `kde-gtk-config` bridge |
| `x11-themes/adwaita-icon-theme` | hard RDEPEND of both GTK slots |
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
| `plan/03-package-set.md` | The largest rewrite: Strategy (profile, global USE — the "X11 libraries stay, Xorg server goes" paragraph is still correct), the `@desktop` table (replace wholesale), "Dropped from the native set" (keep the file-roller / gnome-text-editor history as background, add the KDE equivalents Ark/Kate with the same reasoning), the portals paragraph (portal-kde), plus a new subsection recording the ban list and allowed residue from §4 |
| `plan/00-overview.md:8,25,71` | M2 "GNOME Wayland session via GDM autologin" → Plasma session via Plasma Login Manager autologin; GNOME Software → Discover |
| `plan/01-architecture.md:74,157-158` | Boot flow `graphical.target → GDM → GNOME Shell`, and the autologin rationale |
| `plan/02-build-pipeline.md:35,83,135,154,162,166,172,177,209,211` | Overlay file name, `polkit[gtk]` → `polkit[kde]`, profile string, stage-30 verify names, preset list, and the "GNOME from source dominates" build-time estimate — Qt6 + Frameworks + Plasma is comparable or larger; say so |
| `plan/04-image-and-boot.md:70,109,119,142` | Splash → Plasma Login Manager hand-off |
| `plan/05-updates.md:118-119` | GNOME Software → Discover shows Flatpak updates |
| `plan/06-pruning.md` | The typelib exception (`:20,30`), the xdg-utils/cups/samba cascade (`:110-122`), the "Python under GNOME — RESOLVED" section (`:132-164`) whose entire dependency chain no longer exists, the Qt6/Xorg section (`:202-206`) which now reads the other way round, and the size-budget row (`:255`, "GNOME Shell + GTK4 + Mutter (no webkit) = 1.6 GiB") — replace with a measured figure after the first build |
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
#   review out/reports/expected-packages.txt.generated
cp out/reports/expected-packages.txt.generated config/portage/expected-packages.txt
bash scripts/build.sh --from 50
```

Then, in order:

1. **Audit the generated allowlist before committing it.** This is the gate that makes "minimal"
   true, so read it rather than pasting it:

   ```sh
   grep -iE 'gnome|gdm|mutter|nautilus|gjs|adwaita|webkit|qtwebengine' \
     config/portage/expected-packages.txt
   wc -l config/portage/expected-packages.txt   # compare against today's 521
   ```

   Everything the first command returns must be in the §4 residue table. Anything else means a
   mask is missing or a USE flag is wrong.

2. **Size.** `out/reports/size-report.txt` — compare `/usr` (today 1317 MB) and the total (today
   7674 MB) against the plan/06 budget, and update that table with the real number.

3. **Stage 70 smoke** runs automatically: two boots, `graphical.target` reached,
   `failed_units=0`, machine-id persists, resolved active.

4. **Manual QEMU pass** — the things no automated test can see (stage 70 reads a serial port, so
   an image that boots to a black screen still passes it):

   ```sh
   bash scripts/run-vm.sh out/immos-0.1.0.img
   ```

   - splash appears, then Plasma Login Manager autologins straight into a Plasma **Wayland**
     session (`echo $XDG_SESSION_TYPE` → `wayland`), and `systemctl status plasmalogin` is
     active;
   - the screen locks (`loginctl lock-session`) — that is `kwin[lock]` doing its job, and it is
     the flag most likely to be dropped by accident;
   - Konsole and Dolphin launch; Discover lists Flathub and can install an app;
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

## Settled since the first draft

These were open questions; they are now answered against the pinned tree and folded into the
sections above:

- **IUSE for every `kde-plasma/*` package** — read from the 6.6.6 ebuilds, §1. The corrections
  that mattered: `discover` has no `packagekit` flag; `powerdevil` has no `powerprofiles` flag
  (`brightness-control` is DDC/CI via ddcutil); `kwin` has no `X` flag at all — the X11
  compositor is a separate `kde-plasma/kwin-x11` package; and eleven of the packages have empty
  `IUSE` and need no line.
- **`kwin[lock]`** — not default-on, required by `plasma-login-manager`, and the only thing that
  puts `kscreenlocker` in the image. Missing it would have shipped a laptop that cannot lock.
- **`plasma-workspace` REQUIRED_USE `fontconfig? ( X )`** — and its `X?` block pulls only X
  libraries, never `xorg-server`, so `X` stays on.
- **Keywords** — everything is stable amd64 at Plasma 6.6.6 / Frameworks 6.27.0 / Gear 26.04.3
  except `kde-plasma/plasma-login-manager`. One `package.accept_keywords` entry, pinned to
  `=6.6.6`.
- **`kde-plasma/print-manager`**, not `kde-apps/`.
- **KWallet auto-unlock** — Gentoo's PLM PAM stacks already carry the `pam_kwallet5.so` lines,
  so no stage-40 `/etc/pam.d` edit is needed.

## Open items the first build decides

- **The `plasmalogin` binary path.** Inferred from the ebuild's other paths, not read off an
  installed file list. Stage 30's `have_exe plasmalogin` is where a wrong guess surfaces.
- **PLM's autologin config keys.** Assumed SDDM-compatible (`[Autologin] User/Session/Relogin`)
  because PLM is a fork; confirm against `man plasmalogin.conf` and `/usr/share/plasmalogin/`.
- **`~amd64` blast radius.** `=plasma-login-manager-6.6.6` should need nothing else unkeyworded —
  verify with `emerge -p` before accepting the build, and if it starts pulling a `~amd64` Qt or
  Plasma set, the pin is wrong and the whole PLM choice is worth revisiting.
- Whether `kde-frameworks/kwallet` provides `org.freedesktop.secrets` for Flatpak apps, or a
  separate Secret Service bridge is needed.
- Whether a configure-time RDEPEND-only dep needs adding to `@buildhost` (the tecla-shaped
  failure mode).
- Whether `-introspection` global holds, or some surviving package dlopens a typelib.
- Whether PLM's `pkg_setup` kernel check (`CONFIG_CHECK="~DRM"`, via `linux-info`) is quiet in a
  `--root=$TARGET` build with no `/usr/src/linux` symlink. It is a `~`-prefixed check, so it
  should warn rather than fail — but it is a new eclass in this pipeline's dependency graph.
