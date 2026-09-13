<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE TS>
<!--
  Translations for the fr row of config/languages.conf.

  GENERATED SHAPE, HAND-WRITTEN CONTENT. Calamares loads this file's compiled .qm as its BRANDING
  translator (Branding.cpp:296 builds the prefix <component>/lang/calamares-<component>_, and
  installTranslator() reloads it on every language change), so our modules' tr() and qsTr() strings
  resolve out of it with no QTranslator of our own and no retranslation wiring. See plan/22 §4.

  Source strings must match the C++ and QML BYTE FOR BYTE. Do not reflow them, do not "fix" the
  ellipsis or the em dash: a mismatch is not an error anywhere, it is a string that silently stays
  English. scripts/update-translations.sh re-extracts them with lupdate; stage 40 refuses to build
  a medium whose LanguageNames context is missing a row that config/languages.conf names.

  A CONTEXT IS A CLASS NAME, which is why plan/23 touched this file at all: moving the greeting out
  of the language module moved four strings from LanguageConfig into GreetingPage and GreetingConfig
  without changing one character of any of them. Nothing checks that a context still names a class
  that exists — a stale one is another string that silently stays English — so check-translations.py
  grew a rule for it.

  THREE OF THE CONTEXTS BELOW ARE UPSTREAM'S: CheckerContainer, ResultsListWidget and the
  GreetingViewStep sidebar entry are Calamares' own strings, and their translations are lifted from
  Calamares' own catalogue (lang/calamares_fr.ts in the 3.4.2 tarball) rather than written
  again here. They are in OUR catalogue because upstream's copy is keyed to a source ending in three
  ASCII dots while the code it ships says "…", so Qt never finds it; the trailing dots in the
  translations are normalised to match. That is upstream's bug, fixed for this medium only.

  The accounts page's contexts are NOT here yet — run scripts/update-translations.sh to pull them
  in. Until then that page is English in every language, which plan/22 §8 records as a known limit.
-->
<TS version="2.1" language="fr">
<context>
    <name>CheckerContainer</name>
    <message>
        <source>Gathering system information…</source>
        <translation>Récupération des informations système…</translation>
    </message>
</context>
<context>
    <name>GreetingConfig</name>
    <message>
        <source>This computer can install %1.</source>
        <translation>Cet ordinateur peut installer %1.</translation>
    </message>
    <message>
        <source>This computer cannot install %1.</source>
        <translation>Cet ordinateur ne peut pas installer %1.</translation>
    </message>
</context>
<context>
    <name>GreetingPage</name>
    <message>
        <source>Install medium</source>
        <translation>Support d’installation</translation>
    </message>
    <message>
        <source>This program will ask you a few questions and then install %1 on this computer. Everything already on the disk you choose will be erased.</source>
        <translation>Ce programme va vous poser quelques questions, puis installer %1 sur cet ordinateur. Tout ce qui se trouve sur le disque choisi sera effacé.</translation>
    </message>
</context>
<context>
    <name>GreetingViewStep</name>
    <message>
        <source>Welcome</source>
        <translation>Bienvenue</translation>
    </message>
</context>
<context>
    <name>LanguageConfig</name>
    <message>
        <source>Language</source>
        <translation>Langue</translation>
    </message>
</context>
<context>
    <name>LanguageNames</name>
    <message>
        <source>German</source>
        <translation>Allemand</translation>
    </message>
    <message>
        <source>English</source>
        <translation>Anglais</translation>
    </message>
    <message>
        <source>Spanish</source>
        <translation>Espagnol</translation>
    </message>
    <message>
        <source>French</source>
        <translation>Français</translation>
    </message>
    <message>
        <source>Italian</source>
        <translation>Italien</translation>
    </message>
    <message>
        <source>Portuguese (Brazil)</source>
        <translation>Portugais (Brésil)</translation>
    </message>
    <message>
        <source>Russian</source>
        <translation>Russe</translation>
    </message>
    <message>
        <source>Japanese</source>
        <translation>Japonais</translation>
    </message>
    <message>
        <source>Chinese (Simplified)</source>
        <translation>Chinois (simplifié)</translation>
    </message>
</context>
<context>
    <name>LanguageViewStep</name>
    <message>
        <source>Language</source>
        <translation>Langue</translation>
    </message>
</context>
<context>
    <name>Requirements</name>
    <message>
        <source>Disk</source>
        <translation>Disque</translation>
    </message>
    <message>
        <source>Memory</source>
        <translation>Mémoire</translation>
    </message>
    <message>
        <source>Administrator access</source>
        <translation>Droits d’administrateur</translation>
    </message>
    <message>
        <source>Power</source>
        <translation>Alimentation</translation>
    </message>
    <message>
        <source>Network</source>
        <translation>Réseau</translation>
    </message>
    <message>
        <source>Screen</source>
        <translation>Écran</translation>
    </message>
    <message>
        <source>%1 available, %2 needed</source>
        <translation>%1 disponible, %2 nécessaires</translation>
    </message>
    <message>
        <source>no disk to install onto, %1 needed</source>
        <translation>aucun disque sur lequel installer, %1 nécessaires</translation>
    </message>
    <message>
        <source>the installer is not running with administrator rights</source>
        <translation>l’installateur ne dispose pas des droits d’administrateur</translation>
    </message>
    <message>
        <source>plugged in</source>
        <translation>branché sur le secteur</translation>
    </message>
    <message>
        <source>running on battery</source>
        <translation>sur batterie</translation>
    </message>
    <message>
        <source>connected</source>
        <translation>connecté</translation>
    </message>
    <message>
        <source>not connected, not required</source>
        <translation>non connecté, non requis</translation>
    </message>
    <message>
        <source>no screen found</source>
        <translation>aucun écran détecté</translation>
    </message>
</context>
<context>
    <name>ResultsListWidget</name>
    <message>
        <source>Checking requirements again in a few seconds…</source>
        <translation>Vérifie à nouveau les exigences dans quelques secondes…</translation>
    </message>
</context>
</TS>
