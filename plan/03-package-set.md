# 03 — Package Set

## Strategy

The native set is the **smallest thing that is still a complete GNOME Wayland desktop
with working hardware**. Everything user-facing beyond that is Flatpak. Rule of thumb for
"native or Flatpak?": if it touches hardware, sessions, or system services → native; if it's
an application window → Flatpak.

Profile: `default/linux/amd64/23.0/desktop/gnome/systemd` (merged-usr). Target
`CFLAGS="-march=x86-64 -O2 -pipe"` — generic baseline, because low-power CPUs sold well
within the 5-year window (Goldmont Plus / early Gracemont Celerons) lack AVX2, ruling out
x86-64-v3 as a floor. (An optional `-v3` image variant is a roadmap item.)

Global target USE (in `config/portage/make.conf`), on top of the gnome/systemd profile:

```
USE="wayland pipewire screencast bluetooth vulkan vaapi introspection
     -doc -gtk-doc -examples -test -gnome-online-accounts"
```

Notes: `introspection` is not optional for GNOME — gjs and gnome-shell load GObject typelibs
at runtime. `-gnome-online-accounts` is the main lever keeping `net-libs/webkit-gtk` (a ~2h
build and ~300 MB) out of the native image — anything needing a browser engine lives in
Flatpak; the same reasoning drives the `-oauth` flag on `evolution-data-server`, which
gnome-shell pulls in for the calendar. X11 *libraries* remain (toolkits need them) but the
**Xorg server is excluded — Wayland-only, with `x11-base/xwayland` for legacy-app compat
inside the session.**

## Native package set (Portage sets in `config/portage/sets/`)

### @base — boot + plumbing

| Package | Why |
|---|---|
| sys-apps/baselayout, app-shells/bash, sys-apps/coreutils, sys-apps/util-linux, sys-apps/shadow, sys-libs/pam + sys-auth/pambase | POSIX userland floor |
| sys-apps/systemd (`USE="boot"` for bless-boot/bootctl; **ukify/repart tooling used from builder only**) | init, network glue, sysupdate client, journald |
| sys-apps/dbus, sys-auth/polkit | desktop/system IPC + privilege broker (Flatpak, NM, GNOME Software all need polkit) |
| sys-fs/e2fsprogs, sys-fs/dosfstools | fsck for var + ESP |
| net-misc/networkmanager (`USE="wifi"`, wpa_supplicant backend), net-wireless/wpa_supplicant | networking; wpa_supplicant over iwd for broadest driver compat |
| systemd-resolved (part of sys-apps/systemd; **enabled by preset**, `dns=systemd-resolved` in NM) | name resolution — see "DNS" below |
| app-admin/sudo, net-misc/openssh (installed, **disabled by preset**) | admin & debug access |
| sys-apps/zram-generator | compressed swap, no swap partition |
| sys-apps/flatpak, sys-apps/xdg-desktop-portal, sys-apps/xdg-desktop-portal-gnome | the application layer |
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

### @hardware — kernel, firmware, drivers

| Package | Why |
|---|---|
| sys-kernel/gentoo-kernel-bin | Distribution kernel, Fedora-derived config: broadest module coverage (NVMe, i915/xe, amdgpu, iwlwifi, mt76xx, ath11k/ath12k, rtw88/89, r8169, UVC, SOF, Thunderbolt/USB4…) without maintaining a config. Prebuilt → nothing to compile in-target |
| sys-kernel/linux-firmware (`USE="redistributable -initramfs"`, license `@BINARY-REDISTRIBUTABLE`) | GPU (amdgpu/i915 GuC/HuC), Wi-Fi 6/6E/7, Bluetooth, AMD microcode — the "proprietary blobs for broad compatibility" requirement |
| sys-firmware/intel-microcode | Intel CPU microcode (AMD's ships in linux-firmware); loaded early via kernel |
| sys-firmware/sof-firmware | Sound Open Firmware — audio on virtually every 2020+ Intel laptop |
| **x11-drivers/nvidia-drivers** (`USE="kernel-open dist-kernel"`) | Full NVIDIA stack: proprietary userspace + open GSP kernel modules, prebuilt against gentoo-kernel-bin. `kernel-open` covers **Turing (RTX 20 / GTX 16) and newer** — i.e. essentially all NVIDIA machines in the 5-year window. `nvidia-drm.modeset=1` on cmdline for Wayland. **Tradeoff:** Pascal (GTX 10) and older get kernel `nouveau` + `simpledrm` fallback — usable desktop, weak 3D; documented, accepted (those machines are 8+ years old) |
| media-libs/mesa (`USE="vulkan vaapi"`, `VIDEO_CARDS="amdgpu radeonsi intel nouveau virgl"`) | Intel/AMD/virtio GL+Vulkan, nouveau fallback for pre-Turing NVIDIA, hw video decode |
| media-libs/libva-intel-media-driver, media-libs/libva | Intel Gen11+ video acceleration |
| net-wireless/bluez | Bluetooth daemon |
| sys-apps/fwupd | **deferred to roadmap** (needs ESP-write policy decisions) — listed here so it isn't forgotten |

VM support comes free: virtio-gpu/blk/net + QXL are modules in gentoo-kernel-bin; mesa virgl
covers 3D in QEMU. Known-limitation note for the docs: MIPI/IPU6 webcams (some 2023+ laptops)
have firmware in linux-firmware but an immature userspace stack — out of scope v1.

### @desktop — minimal GNOME

| Package | Why |
|---|---|
| gnome-base/gnome-shell + gnome-base/gnome-session + x11-wm/mutter | the shell, the session, the Wayland compositor |
| gnome-base/gnome-settings-daemon, gnome-base/gnome-control-center, sys-power/power-profiles-daemon | network/audio/power/display — the "it works like a laptop" set. GNOME folds these into the shell rather than shipping separate applets |
| net-wireless/gnome-bluetooth | Bluetooth pairing/UI |
| x11-themes/adwaita-icon-theme, x11-themes/gnome-backgrounds, media-fonts/cantarell | icons/wallpaper/UI font. The Adwaita GTK theme itself ships inside GTK4/libadwaita, so no separate theme package is needed |
| gnome-base/gnome-control-center + gnome-extra/gnome-system-monitor | control panel + task manager (control-center also absorbs printer setup, so there is no separate print manager) |
| gnome-base/gnome-keyring | secrets store for NM/Wi-Fi creds and flatpak apps |
| gnome-base/gdm (`WaylandEnable=true`) | login/autologin. Lock screen needs no extra package — it is built into gnome-shell |
| gnome-extra/gnome-console, gnome-base/nautilus, app-arch/file-roller, app-editors/gnome-text-editor | the four native utilities: terminal, files, archives, text. Native (not Flatpak) because they need unrestricted host access |
| gnome-extra/gnome-software (`USE="flatpak -fwupd -malcontent"`) | GUI software center, **Flatpak backend only** — it cannot even offer native packages |
| media-video/pipewire (`USE="sound-server pipewire-alsa"`) + media-video/wireplumber | audio/video routing (profile default) |
| x11-base/xwayland | legacy X11 app compat inside the Wayland session |
| media-fonts/noto, noto-cjk, noto-emoji | complete Unicode coverage out of the box (CJK is ~large; `build.conf` switch, default **on**) |
| net-print/cups (`build.conf` switch, default **on**) | printing can't be flatpak'd; the GNOME UI for it lives in gnome-control-center |

One base-set addition worth calling out: **app-crypt/gnupg stays in the target** — systemd's
import/verify machinery (which sysupdate uses for `Verify=yes`) spawns the `gpg` binary
against `/usr/lib/systemd/import-pubring.gpg`; it is a genuine runtime dependency of the
update path, listed in `@base`.

Explicitly **absent** natively (Flatpak instead): browser, office, mail, media players, image
viewers/editors, IDEs, games, chat.

## Flatpak layer

- Remote: Flathub, system-wide, configured at build (`flatpak remote-add --if-not-exists
  flathub https://dl.flathub.org/repo/flathub.flatpakrepo` in the target chroot).
- Installs live in `/var/lib/flatpak` → persist across OS updates, fully user-managed.
- **Preinstalled set** (`FLATPAK_PREINSTALL` in `build.conf`), deliberately tiny — default:
  `org.mozilla.firefox`. Each entry adds its runtime; Firefox + org.freedesktop.Platform is
  ~1.5 GiB in `/var`, which is why the default stops there. GNOME Software makes everything else
  one click away.
- `FLATPAK_PREINSTALL_MODE=build|firstboot`: `build` installs during stage 40 (image works
  offline immediately); `firstboot` ships only the remote config and a oneshot unit that
  installs on first network — smaller image, needs connectivity.
- Portals: xdg-desktop-portal-gnome (plus -gtk, which backs the file chooser and settings)
  gives flatpaks file pickers, screenshot/screencast, settings. This is the part that makes
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
