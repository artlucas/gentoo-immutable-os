# config/plasma — the Plasma session's own defaults

Files that configure KDE Plasma itself on every profile that has a desktop, as opposed to
`config/calamares/system/`, which configures the live *installer medium*'s Plasma session and
ships nowhere else. Designed in [plan/17](../../plan/17-animated-splash.md).

## Where it goes

| here | installed as | why there |
|---|---|---|
| `kdeglobals.in` | `/etc/xdg/kdeglobals` | names the package below as the session's Look-and-Feel package — **this is what selects the splash** |
| `ksplashrc.in` | `/etc/xdg/ksplashrc` | names the same package for the reads that never reach a Plasma session |
| `lookandfeel/**` | `/usr/share/plasma/look-and-feel/<id>/` | the Plasma/LookAndFeel package both files name |

[Stage 40](../../scripts/stages/40-configure.sh) installs all three only when the build profile's
sets include `desktop`. A console image has no Plasma to configure.

The package's `contents/splash/images/*.svg`, `contents/splash/Design.qml` and
`contents/previews/splash.png` are **not in this directory**: they are generated at build time by
`config/branding/make-splash-assets.py`, from the same sources and the same layout function that
compose the boot splash. That is the whole design — see
[config/branding/README.md](../branding/README.md).

## The /etc/xdg layer defaults every user

Two files under `/etc/xdg` and nothing else. `$XDG_CONFIG_DIRS` cascades underneath `~/.config`,
so they are the image's defaults for anyone who has not chosen otherwise, and System Settings →
Appearance → Splash Screen still writes a user's own choice to `~/.config/ksplashrc` and wins over
both.

That covers every account this project produces without a skel copy, a first-login hook or a
Calamares job:

| account | how it gets the splash |
|---|---|
| the live user on the product image | reads the file off the read-only root |
| the live user on the installer medium | same file, same root |
| an account Calamares creates | the installed system **is** the desktop profile's root EROFS written to disk, so the file is there before the account exists |

## LookAndFeelPackage, not Theme

This is the correction to the original design, and it cost a release to find. The splash is
selected by `/etc/xdg/kdeglobals`:

```ini
[KDE]
LookAndFeelPackage=<id>
```

`ksplashqml` really does read `ksplashrc` `[KSplash] Theme` first and really does prefer it over
`kdeglobals` — that part of the old note was right. What it missed is **which `ksplashrc`**.
Before any of the session starts, `startplasma`'s `setupPlasmaEnvironment()`
(`plasma-workspace/startkde/startplasma.cpp`):

1. **prepends `~/.config/kdedefaults` to `XDG_CONFIG_DIRS`**, so that directory outranks
   `/etc/xdg` for every KConfig read the session makes; then
2. if `~/.config/kdedefaults/package` does not already name the Look-and-Feel package,
   runs `KLookAndFeelManager` in `Defaults` mode over it, which **writes
   `~/.config/kdedefaults/ksplashrc`** — `Theme` from the package's `contents/defaults`
   `[ksplashrc][KSplash] Theme` if it has one, and **otherwise from the package id itself**
   (`libklookandfeel/klookandfeelmanager.cpp`, `save()`).

So on a fresh account the session's effective `Theme` is the id in `kdeglobals`, in a file that
beats `/etc/xdg`. Ours said `<id>` and was never read; the medium's session was handed
`<id>-installer`, which had no `contents/splash`, and `ksplashqml` fell back to Breeze —
`splashwindow.cpp` does that on any load failure with nothing but a `qCWarning`. On the product,
where no `kdeglobals` was shipped at all, the built-in default `org.kde.breeze.desktop` did the
same thing. Both images booted to Breeze while every config file in them said otherwise.

**One package per image, therefore.** The installer medium's task-manager layout script
([plan/16](../../plan/16-installer.md)) goes into *this* package, added by stage 40 for that
profile only, instead of into a second package that `kdeglobals` would have to name instead. The
product's copy has no `contents/layouts` and the layout resolves to Breeze's.

Everything the package does not ship still resolves to Breeze: plasma-workspace installs
`org.kde.breeze.desktop` as the fallback package for any id but its own, so colours, style, lock
screen, logout and — on the product — the desktop layout are untouched. Applying this as a Global
Theme in System Settings is therefore harmless rather than a way to end up with half a desktop.

One warning that follows from the mechanism above: **do not add a `contents/defaults` to this
package.** `KLookAndFeelManager` reads that file through the same fallback, so shipping one
*replaces* Breeze's wholesale rather than overriding a key in it, and the colours, style, icons
and cursors it would stop writing are the ones every fresh account gets.

## The fade out is kwin's

The theme fades itself **in**; it cannot fade itself out. `SplashApp::setStage()` calls
`QGuiApplication::exit()` the moment the `desktop` stage arrives and only then pushes that stage
to the windows, so the event loop is already unwinding before any animation the QML started could
render a frame.

What actually fades the splash away is kwin's `login` effect — 500 ms of opacity on
`windowClosed`, matched on `windowClass == "ksplashqml ksplashqml"`. It is `EnabledByDefault` and
this image ships no `kwinrc`, so the default applies. Stage 40 asserts the effect is installed and
still enabled by default, because losing it breaks nothing: the splash would simply snap away
instead of fading, on a screen no automated test can see.
