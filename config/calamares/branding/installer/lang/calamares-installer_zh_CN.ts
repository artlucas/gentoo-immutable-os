<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE TS>
<!--
  Translations for the zh_CN row of config/languages.conf.

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
  Calamares' own catalogue (lang/calamares_zh_CN.ts in the 3.4.2 tarball) rather than written
  again here. They are in OUR catalogue because upstream's copy is keyed to a source ending in three
  ASCII dots while the code it ships says "…", so Qt never finds it; the trailing dots in the
  translations are normalised to match. That is upstream's bug, fixed for this medium only.

  The accounts page's contexts are NOT here yet — run scripts/update-translations.sh to pull them
  in. Until then that page is English in every language, which plan/22 §8 records as a known limit.
-->
<TS version="2.1" language="zh_CN">
<context>
    <name>CheckerContainer</name>
    <message>
        <source>Gathering system information…</source>
        <translation>正在收集系统信息…</translation>
    </message>
</context>
<context>
    <name>GreetingConfig</name>
    <message>
        <source>This computer can install %1.</source>
        <translation>这台计算机可以安装 %1。</translation>
    </message>
    <message>
        <source>This computer cannot install %1.</source>
        <translation>这台计算机无法安装 %1。</translation>
    </message>
</context>
<context>
    <name>GreetingPage</name>
    <message>
        <source>Install medium</source>
        <translation>安装介质</translation>
    </message>
    <message>
        <source>This program will ask you a few questions and then install %1 on this computer. Everything already on the disk you choose will be erased.</source>
        <translation>本程序将询问几个问题，然后在这台计算机上安装 %1。所选磁盘上的所有内容都将被清除。</translation>
    </message>
</context>
<context>
    <name>GreetingViewStep</name>
    <message>
        <source>Welcome</source>
        <translation>欢迎</translation>
    </message>
</context>
<context>
    <name>LanguageConfig</name>
    <message>
        <source>Language</source>
        <translation>语言</translation>
    </message>
</context>
<context>
    <name>LanguageNames</name>
    <message>
        <source>German</source>
        <translation>德语</translation>
    </message>
    <message>
        <source>English</source>
        <translation>英语</translation>
    </message>
    <message>
        <source>Spanish</source>
        <translation>西班牙语</translation>
    </message>
    <message>
        <source>French</source>
        <translation>法语</translation>
    </message>
    <message>
        <source>Italian</source>
        <translation>意大利语</translation>
    </message>
    <message>
        <source>Portuguese (Brazil)</source>
        <translation>葡萄牙语（巴西）</translation>
    </message>
    <message>
        <source>Russian</source>
        <translation>俄语</translation>
    </message>
    <message>
        <source>Japanese</source>
        <translation>日语</translation>
    </message>
    <message>
        <source>Chinese (Simplified)</source>
        <translation>简体中文</translation>
    </message>
</context>
<context>
    <name>LanguageViewStep</name>
    <message>
        <source>Language</source>
        <translation>语言</translation>
    </message>
</context>
<context>
    <name>Requirements</name>
    <message>
        <source>Disk</source>
        <translation>磁盘</translation>
    </message>
    <message>
        <source>Memory</source>
        <translation>内存</translation>
    </message>
    <message>
        <source>Administrator access</source>
        <translation>管理员权限</translation>
    </message>
    <message>
        <source>Power</source>
        <translation>电源</translation>
    </message>
    <message>
        <source>Network</source>
        <translation>网络</translation>
    </message>
    <message>
        <source>Screen</source>
        <translation>屏幕</translation>
    </message>
    <message>
        <source>%1 available, %2 needed</source>
        <translation>可用 %1，需要 %2</translation>
    </message>
    <message>
        <source>no disk to install onto, %1 needed</source>
        <translation>没有可安装的磁盘，需要 %1</translation>
    </message>
    <message>
        <source>the installer is not running with administrator rights</source>
        <translation>安装程序未以管理员权限运行</translation>
    </message>
    <message>
        <source>plugged in</source>
        <translation>已接通电源</translation>
    </message>
    <message>
        <source>running on battery</source>
        <translation>使用电池供电</translation>
    </message>
    <message>
        <source>connected</source>
        <translation>已连接</translation>
    </message>
    <message>
        <source>not connected, not required</source>
        <translation>未连接，非必需</translation>
    </message>
    <message>
        <source>no screen found</source>
        <translation>未找到屏幕</translation>
    </message>
</context>
<context>
    <name>ResultsListWidget</name>
    <message>
        <source>Checking requirements again in a few seconds…</source>
        <translation>几秒钟后再次检查要求…</translation>
    </message>
</context>
</TS>
