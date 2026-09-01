// The live medium's Plasma panel: upstream's, with one line changed.
//
// LIVE MEDIUM ONLY. Stage 40 installs this (and the /etc/xdg/kdeglobals that selects the package
// carrying it) for the `installer` profile alone.
//
// WHY THIS FILE EXISTS AT ALL. The Icons-Only Task Manager's stock pins come from its own
// KConfigXT default (plasma-desktop, applets/taskmanager/main.xml):
//
//     applications:systemsettings.desktop,applications:org.kde.discover.desktop,
//     preferred://filemanager,preferred://browser
//
// which on this medium is: System Settings, Discover — an app store on a read-only stick that is
// thrown away in twenty minutes — Dolphin, and a browser that is not installed at all, because
// the installer profile sets FLATPAK_PREINSTALL="" and Firefox travels in the payload instead.
// Four pins, three of them wrong, and not one of them the thing this medium exists to do.
//
// A KConfigXT default cannot be overridden by a config file: Plasma::Corona::config() opens
// plasma-org.kde.plasma.desktop-appletsrc with KConfig::SimpleConfig (libplasma, corona.cpp),
// which does NOT cascade, so an /etc/xdg copy of that file — the trick baloofilerc and
// kscreenlockerrc use — is never read. The layout script is the supported hook, and
// ShellCorona::loadDefaultLayout() takes it from the Look-and-Feel package.

// Upstream's panel, unmodified and by reference: kickoff, pager, icontasks, the system tray, the
// clock, and the input-method panel it adds only for the ~29 languages that need one. Copying
// those 70 lines here to edit one widget's config would silently freeze them at 6.6.6.
loadTemplate("org.kde.plasma.desktop.defaultPanel")

// The one change. applications:calamares.desktop is app-admin/calamares's own menu entry in
// /usr/share/applications — not our /etc/xdg/autostart copy, which is not in an applications
// directory and could not be resolved from here. Upstream's entry is also the translated one
// ("Instalar el sistema", "システムをインストール", …), which matters on a medium whose first
// control is a language picker.
var pinned = 0;
var allPanels = panels();
for (var i = 0; i < allPanels.length; i++) {
    var tasks = allPanels[i].widgets("org.kde.plasma.icontasks");
    for (var t = 0; t < tasks.length; t++) {
        tasks[t].currentConfigGroup = ["General"];
        tasks[t].writeConfig("launchers", ["applications:calamares.desktop"]);
        tasks[t].reloadConfig();
        pinned++;
    }
}
// Not fatal: a panel is far better than no panel, and the medium is still usable with the stock
// pins. Said out loud so it is one grep in the live session's journal rather than a mystery.
if (pinned === 0) {
    print("installer layout: no org.kde.plasma.icontasks widget was found in the default panel; " +
          "the task manager kept its stock launchers");
}

// Verbatim from the Breeze layout this replaces. Without it the desktop containment comes up
// with no wallpaper plugin set.
var desktopsArray = desktopsForActivity(currentActivity());
for (var d = 0; d < desktopsArray.length; d++) {
    desktopsArray[d].wallpaperPlugin = 'org.kde.image';
}
