# config/plasma — the Plasma session's own defaults

Files that configure KDE Plasma itself on every profile that has a desktop, as opposed to
`config/calamares/system/`, which configures the live *installer medium*'s Plasma session and
ships nowhere else. Designed in [plan/17](../../plan/17-animated-splash.md).

## Where it goes

| here | installed as | why there |
|---|---|---|
| `ksplashrc.in` | `/etc/xdg/ksplashrc` | selects the splash below for every user; KConfig cascades it under `~/.config` |
| `lookandfeel/**` | `/usr/share/plasma/look-and-feel/<id>/` | the Plasma/LookAndFeel package `ksplashrc` names |

[Stage 40](../../scripts/stages/40-configure.sh) installs both only when the build profile's
sets include `desktop`. A console image has no Plasma to configure.

The package's `contents/splash/images/*.svg`, `contents/splash/Design.qml` and
`contents/previews/splash.png` are **not in this directory**: they are generated at build time by
`config/branding/make-splash-assets.py`, from the same sources and the same layout function that
compose the boot splash. That is the whole design — see
[config/branding/README.md](../branding/README.md).

## One file defaults every user

`/etc/xdg/ksplashrc` and nothing else. `$XDG_CONFIG_DIRS` cascades underneath `~/.config`, so the
file is the image's default for anyone who has not chosen otherwise, and System Settings →
Appearance → Splash Screen still writes a user's own choice to `~/.config/ksplashrc` and wins.

That covers every account this project produces without a skel copy, a first-login hook or a
Calamares job:

| account | how it gets the splash |
|---|---|
| the live user on the product image | reads the file off the read-only root |
| the live user on the installer medium | same file, same root |
| an account Calamares creates | the installed system **is** the desktop profile's root EROFS written to disk, so the file is there before the account exists |

## Theme, not LookAndFeelPackage

`ksplashqml` resolves its theme in a fixed order (`SplashApp::SplashApp`, then
`SplashWindow::setGeometry`):

1. the command-line argument — `plasma-ksplash.service` passes none
2. `ksplashrc` `[KSplash] Theme` — **this**, and it wins outright
3. `kdeglobals` `[KDE] LookAndFeelPackage`
4. the default Plasma/LookAndFeel package (Breeze)

Using (2) rather than (3) is what lets the installer medium keep `LookAndFeelPackage=<id>-installer`
for its task-manager layout ([plan/16](../../plan/16-installer.md)) *and* get this splash, out of
two small packages. Merging them would ship the installer's layout script to every installed
machine.

Everything the package does not ship still resolves to Breeze: plasma-workspace installs
`org.kde.breeze.desktop` as the fallback package for any id but its own, so colours, style, lock
screen, logout and the desktop layout are untouched — and applying this as a Global Theme in
System Settings is harmless rather than a way to end up with half a desktop.

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
