# 03 — Package Set

## Strategy

The native set is the **smallest thing that is still a complete KDE Plasma 6 Wayland desktop
with working hardware**. Everything user-facing beyond that is Flatpak. Rule of thumb for
"native or Flatpak?": if it touches hardware, sessions, or system services → native; if it's
an application window → Flatpak.

> The desktop was GNOME through 0.1.0 and is Plasma from this change on (plan/09). The rule
> above did not change, and neither did anything below the desktop: boot, EROFS root, UKI,
> A/B sysupdate, the `/etc` overlay, the plymouth splash and image assembly are untouched. The
> Plasma set is a **1:1 functional mirror** of the GNOME one, not a full Plasma install.

Profile: `default/linux/amd64/23.0/desktop/plasma/systemd` (merged-usr). Target
`CFLAGS="-march=x86-64 -O2 -pipe"` — generic baseline, because low-power CPUs sold well
within the 5-year window (Goldmont Plus / early Gracemont Celerons) lack AVX2, ruling out
x86-64-v3 as a floor. (An optional `-v3` image variant is a roadmap item.)

Global target USE (in `config/portage/make.conf`), on top of the plasma/systemd profile:

```
USE="wayland pipewire screencast bluetooth vulkan vaapi
     -doc -gtk-doc -examples -test
     -handbook -telemetry -webengine -designer
     -gnome -gnome-keyring -gnome-online-accounts -introspection -vala"
```

Each negative token earns its place:

- `-handbook` — KDE ships a DocBook handbook per app; nothing in the image can render one
  (no khelpcenter, no yelp), and they install under `/usr/share/doc/HTML`, which stage 50
  deletes anyway.
- `-telemetry` — drops `kde-frameworks/kuserfeedback` and the KDE telemetry surface.
- `-webengine` — the structural guard against `dev-qt/qtwebengine`, a Chromium build.
  Nothing native renders HTML here; backed by a hard mask. This is the Plasma-side equivalent
  of the `-gnome-online-accounts`/`-oauth` levers that kept `net-libs/webkit-gtk` out.
- `-designer` — Qt Designer plugins, in an image with no IDE.
- `-gnome`, `-gnome-keyring`, `-gnome-online-accounts` — global levers stopping packages from
  offering GNOME integration. `-gnome` is specifically load-bearing for `x11-misc/xdg-utils`.
- `-introspection` — was **positive** under GNOME, because gjs and gnome-shell load GObject
  typelibs at runtime. Nothing in the image does that now. Note that *dropping* the token was
  not enough: most packages that build typelibs default the flag on in their own `IUSE`, so it
  has to be negated. `dev-libs/glib` keeps it as a per-package line.
- `-vala` — `.vapi` files are build-time inputs for compiling Vala and stage 50 deletes
  `usr/share/vala` wholesale, so the flag only ever built files the prune threw away. It is
  also what makes `-introspection` *viable*: `gnome-base/librsvg` and `app-crypt/libsecret`
  both carry `REQUIRED_USE="vala? ( introspection )"`, so with vala left on the depgraph stops.

X11 *libraries* remain (toolkits need them) but the **Xorg server is excluded — Wayland-only,
with `x11-base/xwayland` for legacy-app compat inside the session.** Under GNOME that took
three separate `-X` flags; under Plasma it takes two, `nvidia-drivers[-X]` and
`plasma-login-sessions[-X]`, because `kde-plasma/kwin` is Wayland-only by construction and the
X11 compositor is a separate package (`kde-plasma/kwin-x11`) nothing pulls. Confirmed by a
dry-run depgraph against the pinned tree: no `xorg-server`, no `xf86-*` in the resolved set.

## Native package set (Portage sets in `config/portage/sets/`)

### @base — boot + plumbing

| Package | Why |
|---|---|
| sys-apps/baselayout, app-shells/bash, sys-apps/coreutils, sys-apps/util-linux, sys-apps/shadow, sys-libs/pam + sys-auth/pambase | POSIX userland floor |
| sys-apps/systemd (`USE="boot"` for bless-boot/bootctl; **ukify/repart tooling used from builder only**) | init, network glue, sysupdate client, journald |
| sys-apps/dbus, sys-auth/polkit (`USE="kde -gtk"`) | desktop/system IPC + privilege broker (Flatpak, NM and Discover all need polkit). `kde` rather than `gtk`: `polkit[gtk]` is what pulled `gnome-extra/polkit-gnome` in |
| sys-fs/e2fsprogs, sys-fs/dosfstools | fsck for var + ESP |
| net-misc/networkmanager (`USE="wifi"`, wpa_supplicant backend), net-wireless/wpa_supplicant | networking; wpa_supplicant over iwd for broadest driver compat |
| systemd-resolved (part of sys-apps/systemd; **enabled by preset**, `dns=systemd-resolved` in NM) | name resolution — see "DNS" below |
| app-admin/sudo, net-misc/openssh (installed, **disabled by preset**) | admin & debug access |
| sys-apps/zram-generator | compressed swap, no swap partition |
| **sys-boot/plymouth** (`USE="drm udev -pango -freetype -gtk"`) | boot splash. In @base, not @desktop: it runs from the initrd long before a desktop exists, and the `--console-only` image is branded too. Every glyph and shape is a PNG rasterised at build time from `config/branding/`, so it needs no text engine — `-pango`/`-freetype` drop the label and prompt renderers, `-gtk` the X11 renderer that a UKI/DRM boot can never use. Stable amd64 is 22.02.122-r4; 24.004.60 is `~amd64` **and** package-masked upstream, so no keyword exception belongs here. Two build-only companions, `gnome-base/librsvg[tools]` (`rsvg-convert`) and `media-fonts/ibm-plex`, live in `builder/Dockerfile` and never enter the image |
| sys-apps/flatpak, sys-apps/xdg-desktop-portal, kde-plasma/xdg-desktop-portal-kde | the application layer. The KDE backend implements the full interface set (FileChooser, Settings, Screenshot, ScreenCast, Print, Inhibit, Account, GlobalShortcuts), so no `-gtk` backend is needed alongside it |
| app-arch/zstd, app-arch/xz-utils | decompression for sysupdate payloads |
| net-misc/curl, ca-certificates | update fetch + TLS trust |
| app-crypt/gnupg | runtime dep of update verification — systemd's pull/verify machinery spawns `gpg` (see note under the desktop set) |

#### DNS

systemd-resolved is the resolver, and it is wired in three places that only work together:

- **`/etc/nsswitch.conf`** (shipped by the overlay) puts `resolve [!UNAVAIL=return]` first on
  the `hosts:` line, so lookups go over resolved's varlink socket rather than through glibc's
  `dns` module. `dns` stays last as the fallback for the case resolved is not running.
  `mymachines` is deliberately absent — it needs `systemd[importd]`, which is not built here.
- **`/etc/resolv.conf`** is a symlink to `../run/systemd/resolve/stub-resolv.conf`, created in
  stage 40. It dangles at build time, which is load-bearing: `target_mount()` copies the
  builder's nameservers *through* it into the tmpfs mounted on the target's `/run`, so the
  chroot resolves during the build and the builder's DNS config leaves with the tmpfs. Before
  resolved, that copy was landing in the image's read-only `/etc` (fixed in 9284cec).
- **NetworkManager** is told `dns=systemd-resolved` and `rc-manager=unmanaged`
  (`/usr/lib/NetworkManager/conf.d/10-dns-resolved.conf`): publish leases to resolved over
  D-Bus, and never write `resolv.conf`. NM would auto-detect resolved from the stub symlink,
  but that is a heuristic on a file the `/etc` overlay lets anyone replace.

LLMNR is off (`/usr/lib/systemd/resolved.conf.d/10-image.conf`) — a Windows protocol nothing
here speaks, whose responder answers spoofable queries on every network the laptop joins.
MulticastDNS stays on for `.local` device discovery.

Each piece is asserted at build time (stage 40 verify: the symlink target, the `hosts:` line,
the enabled unit, and the presence of `libnss_{resolve,systemd,myhostname}`; stage 50: that
the prune did not cut them; stage 70: `resolved=yes` from the booted guest). Any one of them
failing silently degrades to "DNS mostly works", which is why none of them is left implicit.

### systemd-networkd is removed, not just disabled

NetworkManager owns the network, so networkd has no job in this image. `sys-apps/systemd` has
no USE flag that omits it — it is built unconditionally — so stage 50 deletes it: the two
daemons, `systemd-network-generator`, `networkctl`, their units, the `org.freedesktop.network1`
D-Bus/polkit surface, and the `systemd-network` user's sysusers/tmpfiles entries.

Disabling alone was not enough. The "exactly one network manager" invariant was held by preset
lines plus stage 40's disable loop, which only warns on failure; a systemd bump that changes a
vendor preset would put the image back in the two-managers state that broke boot in 3e52475.
A binary that is not in the image cannot be re-enabled by anything.

The one trap: `/usr/lib/systemd/network` holds networkd config *and* `.link` files, and `.link`
files belong to systemd-udevd, not networkd. `99-default.link` and `73-usb-net-by-mac.link`
drive interface naming and MAC policy, so only `.network`/`.netdev` are removed — and stage 50
asserts `99-default.link` survived, since losing it would surface only as a machine that boots
with no network.

### @hardware — kernel, firmware, drivers

| Package | Why |
|---|---|
| sys-kernel/gentoo-kernel-bin | Distribution kernel, Fedora-derived config: broadest module coverage (NVMe, i915/xe, amdgpu, iwlwifi, mt76xx, ath11k/ath12k, rtw88/89, r8169, UVC, SOF, Thunderbolt/USB4…) without maintaining a config. Prebuilt → nothing to compile in-target |
| sys-kernel/linux-firmware (`USE="redistributable -initramfs"`, license `@BINARY-REDISTRIBUTABLE`) | GPU (amdgpu/i915 GuC/HuC), Wi-Fi 6/6E/7, Bluetooth, AMD microcode — the "proprietary blobs for broad compatibility" requirement |
| sys-firmware/intel-microcode | Intel CPU microcode (AMD's ships in linux-firmware); loaded early via kernel |
| sys-firmware/sof-firmware | Sound Open Firmware — audio on virtually every 2020+ Intel laptop |
| **x11-drivers/nvidia-drivers** (`USE="kernel-open dist-kernel"`) | Full NVIDIA stack: proprietary userspace + open GSP kernel modules, prebuilt against gentoo-kernel-bin. `kernel-open` covers **Turing (RTX 20 / GTX 16) and newer** — i.e. essentially all NVIDIA machines in the 5-year window. `nvidia-drm.modeset=1` on cmdline for Wayland. The ebuild blacklists kernel `nouveau` unconditionally via `/etc/modprobe.d/nvidia.conf` (plan/10), so it was never a real fallback for older cards even before nouveau was dropped from the package set below. **Tradeoff:** Pascal (GTX 10) and older get no working GPU driver at all — no `simpledrm` in this kernel config either (plan/08); accepted, those machines are 8+ years old and outside the 5-year window |
| media-libs/mesa (`USE="vulkan vaapi"`, `VIDEO_CARDS="amdgpu radeonsi intel virgl nvidia"`) | Intel/AMD/virtio GL+Vulkan, hw video decode. No `nouveau`: dead weight per the row above — mesa's gallium nouveau driver and (had `nvidia-drivers[X]` ever been re-enabled) `x11-drivers/xf86-video-nouveau` for a kernel module that can't load |
| media-libs/libva-intel-media-driver, media-libs/libva | Intel Gen11+ video acceleration |
| net-wireless/bluez | Bluetooth daemon |
| sys-apps/fwupd | **deferred to roadmap** (needs ESP-write policy decisions) — listed here so it isn't forgotten |

VM support comes free: virtio-gpu/blk/net + QXL are modules in gentoo-kernel-bin; mesa virgl
covers 3D in QEMU. Known-limitation note for the docs: MIPI/IPU6 webcams (some 2023+ laptops)
have firmware in linux-firmware but an immature userspace stack — out of scope v1.

### @desktop — minimal KDE Plasma 6

| Package | Why |
|---|---|
| kde-plasma/plasma-workspace + kde-plasma/plasma-desktop + kde-plasma/kwin | the shell, the desktop, the Wayland compositor. `kwin` has **no `X` flag** — it is Wayland-only and `kde-plasma/kwin-x11` is a separate package nothing here pulls |
| kde-plasma/systemsettings, kde-plasma/plasma-nm, kde-plasma/plasma-pa, kde-plasma/powerdevil, kde-plasma/kscreen, kde-plasma/bluedevil, sys-power/power-profiles-daemon | network/audio/power/display/Bluetooth — the "it works like a laptop" set. Plasma ships these as separate KCMs and applets where GNOME folded them into the shell, which is why the row is longer without being larger |
| kde-plasma/breeze, kde-frameworks/breeze-icons, kde-plasma/plasma-workspace-wallpapers | widget style, icons, wallpapers |
| kde-plasma/breeze-gtk + kde-plasma/kde-gtk-config | the GTK theming bridge, so Flatpak apps (Firefox is preinstalled) are not an unstyled island. This is the one thing that keeps "remove all GNOME" from being literal — see "Allowed GNOME residue" below |
| kde-plasma/kwallet-pam | secrets store for NM/Wi-Fi creds and Flatpak apps, unlocked at login. Needs **no** `/etc/pam.d` edit: Gentoo's Plasma Login Manager PAM stacks already carry `-auth`/`-session optional pam_kwallet5.so`, and the leading `-` makes them no-ops if the module is absent |
| kde-plasma/polkit-kde-agent | the polkit authentication agent (`sys-auth/polkit[kde]`, replacing `polkit[gtk]` → polkit-gnome) |
| kde-plasma/plasma-login-manager + kde-plasma/plasma-login-sessions | login/autologin, and the `/usr/share/wayland-sessions/plasma.desktop` the greeter logs in *to*. See "Plasma Login Manager" below. Lock screen is **not** free here the way it was inside gnome-shell: `kwin[lock]` is what puts `kde-plasma/kscreenlocker` in the image |
| kde-apps/konsole, kde-apps/dolphin | the two native utilities: terminal and files. Native (not Flatpak) because they need unrestricted host access |
| kde-apps/kio-extras | the gvfs equivalent — trash, network, thumbnails, and `smb://` (see "samba" below) |
| kde-plasma/discover (`USE="flatpak -firmware -snap"`) | GUI software center, **Flatpak backend only**. There is no `packagekit` flag; the PackageKit backend is simply not built unless firmware or snap are |
| kde-plasma/plasma-systemmonitor | task manager |
| media-video/pipewire (`USE="sound-server pipewire-alsa"`) + media-video/wireplumber | audio/video routing (profile default) |
| x11-base/xwayland | legacy X11 app compat inside the Wayland session |
| media-fonts/noto, noto-cjk, noto-emoji | complete Unicode coverage out of the box (CJK is ~large; `build.conf` switch, default **on**). Breeze uses Noto Sans, so no `media-fonts/cantarell` equivalent is needed |
| net-print/cups + kde-plasma/print-manager (`build.conf` switch, default **on**) | printing can't be flatpak'd. Note the category: `kde-plasma/print-manager`, not `kde-apps/`. It talks to CUPS directly, so unlike GNOME's control-center panel it needs no `app-admin/system-config-printer` |

One base-set addition worth calling out: **app-crypt/gnupg stays in the target** — systemd's
import/verify machinery (which sysupdate uses for `Verify=yes`) spawns the `gpg` binary
against `/usr/lib/systemd/import-pubring.gpg`; it is a genuine runtime dependency of the
update path, listed in `@base`.

Explicitly **absent** natively (Flatpak instead): browser, office, mail, media players, image
viewers/editors, IDEs, games, chat, **archive manager and text editor**.

### Plasma Login Manager, not SDDM

Plasma Login Manager (PLM) is KDE's SDDM replacement, released alongside Plasma 6.6 and forked
from SDDM. It reuses `kwin` as its greeter compositor rather than starting a second one, which
is the right shape for an image that is Wayland-only by construction, and it is where the
ecosystem is going (Fedora 44 ships it as the KDE default).

**The one cost, stated plainly:** `kde-plasma/plasma-login-manager` is `~amd64` at the pinned
snapshot — the *only* package in the whole desktop set that is not stable-keyworded — whereas
`x11-misc/sddm` has a stable version. `config/portage/package.accept_keywords/image` opens with
"Keep empty if possible — stable amd64 only", so this is a deliberate departure recorded there
rather than slipped in. It is pinned to **`=6.6.6`**: both `6.6.6-r1` and `6.7.4-r1` raise
`QTMIN` to `>=6.11.2`, which is itself `~amd64` and would drag a `~amd64` Qt *and* a `~amd64`
Plasma 6.7.4 stack in behind it. One `~amd64` package, not a hundred — verified by dry-run
depgraph, which resolves with exactly three `~amd64` entries: this, `nvidia-drivers` and
`libva-intel-media-driver`.

### File indexing

`kde-frameworks/baloo` replaces `app-misc/localsearch` + `app-misc/tinysparql`. **This is not a
new capability** — the GNOME image indexed too, and `app-text/poppler[cairo]` was kept
specifically so `localsearch[pdf]` could read PDFs — which is why the localsearch/tinysparql
entries in `package.mask/image` ban a *duplicate* indexer rather than indexing itself.

None of the four packages it brings (`baloo`, `kfilemetadata`, `kde-apps/baloo-widgets`,
`dev-db/lmdb`) belongs in `@desktop`: plasma-workspace and plasma-desktop pull baloo, dolphin
pulls baloo-widgets, baloo pulls the other two. Listing them would only invite version pins the
set does not own. Two deliberate choices sit on top:

- **The extractor set** is `kfilemetadata`'s entire configuration surface (`baloo` itself has an
  empty `IUSE`): `exif pdf ffmpeg taglib -epub -mobi`. `ffmpeg` is free — `media-video/ffmpeg`
  is already in the image; `taglib` is ~1 MB and covers a music library; `epub`/`mobi` would add
  new packages for formats this image sends to Flatpak readers.
- **`only basic indexing=true`** in `/etc/xdg/baloofilerc` — names and metadata, not file
  *contents*. Content extraction is what makes the index large and the first login I/O-heavy;
  names, tags and EXIF/ID3/PDF metadata are what Dolphin's Find bar and KRunner actually use. A
  user who wants full-text ticks one box in System Settings and re-indexes into their own
  `~/.config/baloofilerc`, which cascades over the `/etc/xdg` layer.

The index lives at `~/.local/share/baloo/index` — under `/var/home/<user>`, i.e. on the
growable var partition, never on the read-only erofs root. See plan/05 for what a factory reset
does to it.

### samba, and the perl interpreter it costs

`kde-apps/kio-extras[samba]` is kept deliberately, for `smb://` browsing in Dolphin. It is now
the *only* thing holding `net-fs/samba` in the image — and samba lists `dev-lang/perl:=` and
`dev-perl/Parse-Yapp` in `COMMON_DEPEND` with no USE guard, so **the image ships a perl
interpreter**. That was already true under GNOME at one more remove (the printer panel pulled
`system-config-printer` → samba); the holder changed, the dependency fact did not. The escape
hatch is one flag: `kio-extras[-samba]` drops samba, perl and Parse-Yapp together, at the cost
of `smb://`. See plan/06.

### Allowed GNOME residue

Keeping the GTK theming bridge means "remove all GNOME" cannot be literal. `kde-gtk-config`
DEPENDs `x11-libs/gtk+:3[X]`, GTK3 hard-RDEPENDs `x11-themes/adwaita-icon-theme`, and that
RDEPENDs `gnome-base/librsvg`. These packages legitimately remain, and
`config/portage/package.mask/image` names them as deliberately *not* masked:

| Package | Held by |
|---|---|
| `dev-libs/glib` | flatpak, NetworkManager, polkit, pipewire — desktop-independent |
| `net-libs/glib-networking` | glib's TLS backend; flatpak's HTTP path |
| `x11-libs/gtk+` (GTK **3**), `x11-libs/gdk-pixbuf`, `x11-libs/pango` | the `breeze-gtk` / `kde-gtk-config` bridge |
| `x11-themes/adwaita-icon-theme` (+ `-legacy`) | hard RDEPEND of GTK3 |
| `gnome-base/librsvg` | RDEPEND of adwaita-icon-theme (SVG icon loading) |
| `gnome-base/dconf`, `gnome-base/gsettings-desktop-schemas` | GSettings backend + schemas the bridge reads |

Everything else in the `gnome-*` space is masked, which makes the absence structural rather
than incidental — and a mask fails the build *at dependency resolution*, naming the package
that pulled the offender, instead of showing up as a 500-line diff at stage 50. That is not
hypothetical: it is how `x11-misc/xdg-user-dirs[gtk]` → `xdg-user-dirs-gtk` was caught.

**`gui-libs/gtk` (GTK 4) leaves the image.** The bridge needs only `:3`, `breeze-gtk` is a pure
theme with no runtime GTK dependency at all, and nothing else in the Plasma set links GTK4.

### Dropped from the native set

`app-arch/file-roller` and `app-editors/gnome-text-editor` were in `@desktop` through 0.1.0 as
two of "the four native utilities". Both are gone; the rule in "Strategy" is what settles it —
they are application windows, not hardware, sessions or system services.

- **file-roller** had *no* unique dependency tail: `app-arch/libarchive` is required by
  flatpak, systemd, gvfs, samba and ostree, and `app-arch/gnome-autoar` by gnome-shell and
  nautilus, so both stayed either way. Its removal was ~0.7 MB.
- **gnome-text-editor** was the sole consumer of a 12-package tail:
  `gui-libs/gtksourceview`, `app-text/libspelling`, `app-text/enchant`, `app-text/hunspell`,
  `app-text/editorconfig-core-c`, and the seven `app-dicts/myspell-*` dictionaries that
  hunspell PDEPENDs per `L10N` (`myspell-de` alone is ~10 MB compressed). `app-editors/nano`
  stays — it is held by `virtual/editor` ← `app-admin/sudo`, independent of this change.

**`kde-apps/ark` and `kde-apps/kate` are not added back in their place**, for the same reason,
and neither are `okular` or `gwenview`. Each is one click away in Discover. Note that Plasma
does not get archive handling for free the way nautilus did through gnome-autoar — that is a
real, accepted difference, not an oversight.

The hunspell tail is worth one more line, because it came back from a different direction:
`kde-frameworks/sonnet[hunspell]` is default-on and pulls the same `app-text/hunspell` +
`app-dicts/myspell-*` chain — and in fact **fails the depgraph outright** here, since this
image's `L10N` uses plain `en` while `myspell-en`'s `REQUIRED_USE` demands one of
`en-AU/en-CA/en-GB/en-US/en-ZA`. Fixed with `sonnet[-hunspell,-aspell]` rather than by widening
`L10N`: nothing in this image is a text editor, and Flatpak editors bring their own dictionaries.

Neither GNOME app is added to `FLATPAK_PREINSTALL`. `org.gnome.FileRoller` and
`org.gnome.TextEditor` both run on `org.gnome.Platform`, which is **~1.07 GB installed** —
preinstalling either would cost more `/var` than the entire native tail this removes from the
read-only root, and `/var` is 4 GiB already carrying Firefox on the freedesktop runtime.

## Flatpak layer

- Remote: Flathub, system-wide, configured at build (`flatpak remote-add --if-not-exists
  flathub https://dl.flathub.org/repo/flathub.flatpakrepo` in the target chroot).
- Installs live in `/var/lib/flatpak` → persist across OS updates, fully user-managed.
- **Preinstalled set** (`FLATPAK_PREINSTALL` in `build.conf`), deliberately tiny — default:
  `org.mozilla.firefox org.kde.Spectacle`. Each entry adds its runtime; Firefox +
  org.freedesktop.Platform is ~1.5 GiB in `/var`, which is why the default stops at a browser
  and a screenshot tool. Discover makes everything else one click away.
- `FLATPAK_PREINSTALL_MODE=build|firstboot`: `build` installs during stage 40 (image works
  offline immediately); `firstboot` ships only the remote config and a oneshot unit that
  installs on first network — smaller image, needs connectivity.
- Portals: xdg-desktop-portal-kde gives flatpaks file pickers, screenshot/screencast and
  settings. It implements the whole interface set on its own, so unlike the GNOME image there
  is no second `-gtk` backend — that package is masked. This is the part that makes
  "minimal native, everything Flatpak" actually pleasant.

## Licenses

`config/portage/package.license/` accepts exactly what's needed, not `ACCEPT_LICENSE="*"`:

```
sys-kernel/linux-firmware   linux-fw-redistributable no-source-code
sys-firmware/intel-microcode intel-ucode
sys-firmware/sof-firmware    BSD  (already free)
x11-drivers/nvidia-drivers   NVIDIA-r2
```

Redistribution: everything above permits redistribution in images (linux-firmware
redistributable set, Intel microcode license, NVIDIA driver EULA permits redistribution
with conditions — note added to release checklist to keep the EULA text at
`/usr/share/licenses/nvidia-drivers/` in the image).

## Dependency audit (build-time gate)

Because RDEPENDs land in the target automatically, stage 30 emits
`out/reports/target-packages.txt` (from the target VDB, pre-prune) and stage 50 diffs it
against a **committed allowlist** (`config/portage/expected-packages.txt`). A new transitive
runtime dep (e.g. something suddenly dragging in python) fails the build until a human either
allowlists it or fixes the USE flags. This is the mechanism that keeps "minimal" true over time.
