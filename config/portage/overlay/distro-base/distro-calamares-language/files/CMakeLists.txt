# SPDX-License-Identifier: GPL-3.0-or-later
#
# The Calamares view module for the language page (plan/22).
#
# Built OUT OF TREE against the installed Calamares, the same supported workflow the accounts
# module uses: CalamaresConfig.cmake exports Calamares::calamares and Calamares::calamaresui and
# puts Calamares' own CMakeModules on CMAKE_MODULE_PATH, so calamares_add_plugin() below is
# upstream's macro rather than a reimplementation. That matters because the macro is what writes
# module.desc, and a descriptor ModuleManager does not recognise is skipped in silence — which for
# THIS module means an installer that opens on the timezone page.
cmake_minimum_required(VERSION 3.20)
project(calamares-language VERSION 1.0 LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Calamares REQUIRED)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Qml Quick QuickWidgets QuickControls2)

# KF6::CoreAddons is named in Calamares::calamares' INTERFACE_LINK_LIBRARIES, so linking against
# Calamares drags it in — but nothing DEFINES that imported target unless someone looks for it,
# and CalamaresConfig.cmake does not: its accumulate_deps() matches target prefixes against a
# lowercase "kf6::" while the targets are spelled "KF6::CoreAddons", CMake's MATCHES is
# case-sensitive, and the whole find_package(KF6) branch is therefore skipped. The failure lands
# here instead, at generate time, as "Target links to KF6::CoreAddons but the target was not
# found". Same finding as the accounts module's; same one-line fix.
#
# KF6CoreAddons, not KF6 COMPONENTS CoreAddons: the umbrella FindKF6.cmake is an ECM find-module
# and would make extra-cmake-modules a build dependency for no other reason.
find_package(KF6CoreAddons REQUIRED)

# The plugin includes "GlobalStorage.h", "viewpages/ViewStep.h" and "modulesystem/Requirement.h"
# by their in-tree paths, which is how every Calamares module spells them; Calamares_INCLUDE_DIRS
# is what makes those resolve from an installed prefix.
include_directories(${Calamares_INCLUDE_DIRS})

# language.conf, the packaged fallback, does not install itself. calamares_add_plugin() globs
# *.conf out of this directory and then guards the install on `if(INSTALL_CONFIG)` — an option
# Calamares' own top-level CMakeLists defines for its in-tree modules and CalamaresConfig.cmake
# does not export, so out of tree it is undefined and reads as false. Nothing warns: the glob DID
# find the file, so the macro also skips the "NO_CONFIG should be set." advice it prints for a
# plugin with no configuration at all.
#
# NOT `NO_CONFIG`, which would be the other way to silence the same glob: that stamps
# `noconfig: true` into module.desc and Calamares then never calls setConfigurationMap() — this
# page would come up with no languages and no requirement checks, which is a blank first screen.
#
# The medium always gets the RENDERED /etc/calamares/modules/language.conf, whose `languages:`
# list stage 40 writes out of config/languages.conf. The packaged copy exists so the module is
# loadable on its own, and its list is deliberately English-only: a fallback that guessed at nine
# languages would be a second source of truth for the one thing plan/22 §2b made single.
#
# That file used to carry a `requirements:` block as well. It is greeting.conf's now, along with
# Requirements.cpp — a requirement is contributed by whichever module is in the sequence, so the
# checks moved with the page that reports them (plan/23 §3).
set(INSTALL_CONFIG ON)

calamares_add_plugin(language
    TYPE viewmodule
    EXPORT_MACRO PLUGINDLLEXPORT_PRO
    SOURCES
        LanguageViewStep.cpp
        LanguageConfig.cpp
    LINK_LIBRARIES
        Calamares::calamares
        Calamares::calamaresui
        Qt6::Gui
        Qt6::Widgets
        Qt6::Qml
        Qt6::Quick
        Qt6::QuickWidgets
        Qt6::QuickControls2
    SHARED_LIB
)

# The target name is calamares_add_plugin's, not ours: CalamaresAddPlugin.cmake builds it as
# "calamares_${TYPE}_${NAME}". Asserting it rather than assuming it means an upstream rename fails
# HERE, with this message, instead of at qt6_add_resources with CMake's own "add_library called
# with incorrect number of arguments".
set(LANGUAGE_TARGET calamares_viewmodule_language)
if(NOT TARGET ${LANGUAGE_TARGET})
    message(FATAL_ERROR
        "calamares_add_plugin did not create ${LANGUAGE_TARGET}; upstream's target-naming "
        "convention has changed and the resource call below needs the new name")
endif()

# THE QML TRAVELS INSIDE THE .so. Calamares::QmlViewStep would load it by name out of the branding
# component directory or /usr/share/calamares/qml — a second install path, a second search order,
# and a page that renders blank if either is wrong, with nothing in the log. A resource cannot be
# half-installed.
qt6_add_resources(${LANGUAGE_TARGET} "language_qml"
    PREFIX "/language"
    FILES
        # The design system's tokens (plan/28). NOT in this directory in the repository —
        # config/calamares/qml/Theme.qml is the one copy, and scripts/stages/20-builder-setup.sh
        # stages it here for every module whose CMakeLists names it, which is this line. Naming it
        # is therefore how a module opts in; a page that instantiates Theme{} without this line
        # fails to load with a QML type error and renders blank.
        qml/Theme.qml
        qml/Language.qml
)
