# SPDX-License-Identifier: GPL-3.0-or-later
#
# The Calamares view module for the location page (plan/28 §6).
#
# Built OUT OF TREE against the installed Calamares, the same supported workflow its five siblings
# use: CalamaresConfig.cmake exports Calamares::calamares and Calamares::calamaresui and puts
# Calamares' own CMakeModules on CMAKE_MODULE_PATH, so calamares_add_plugin() below is upstream's
# macro rather than a reimplementation. The macro is what writes module.desc, and a descriptor
# ModuleManager does not recognise is skipped in silence — which for THIS module means an
# installer that never asks where the machine is — and then an installed system whose clock is
# UTC, because that is what the image ships and nothing would have changed it.
cmake_minimum_required(VERSION 3.20)
project(calamares-location VERSION 1.0 LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Calamares REQUIRED)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Qml Quick QuickWidgets QuickControls2)

# KF6::CoreAddons is named in Calamares::calamares' INTERFACE_LINK_LIBRARIES, so linking against
# Calamares drags it in — but nothing DEFINES that imported target unless someone looks for it,
# and CalamaresConfig.cmake does not: its accumulate_deps() matches target prefixes against a
# lowercase "kf6::" while the targets are spelled "KF6::CoreAddons", CMake's MATCHES is
# case-sensitive, and the whole find_package(KF6) branch is skipped. The failure lands here
# instead, at generate time. Sixth module, same one-line fix.
find_package(KF6CoreAddons REQUIRED)

# The plugin includes "GlobalStorage.h", "viewpages/ViewStep.h" and — the one that matters here
# — "locale/TimeZone.h", which is where RegionsModel, ZonesModel and RegionalZonesModel come from.
# They are DLLEXPORT and installed, which is the whole reason this module parses no tzdata and
# ships no table of its own. Calamares_INCLUDE_DIRS is what makes those resolve from an installed
# prefix.
include_directories(${Calamares_INCLUDE_DIRS})

# location.conf, the packaged fallback, does not install itself: calamares_add_plugin() globs *.conf
# out of this directory and guards the install on `if(INSTALL_CONFIG)`, an option Calamares' own
# top-level CMakeLists defines for its in-tree modules and CalamaresConfig.cmake does not export —
# so out of tree it is undefined and reads as false, silently. The medium always gets the RENDERED
# /etc/calamares/modules/location.conf; the packaged copy exists so the module is loadable on its own.
#
# NOT `NO_CONFIG`, which would be the other way to silence the same glob: that stamps
# `noconfig: true` into module.desc and Calamares then never calls setConfigurationMap() — so the
# page would open on no default at all rather than on the Etc/UTC the image actually ships, and
# would publish nothing for `localesetup` to read.
set(INSTALL_CONFIG ON)

calamares_add_plugin(location
    TYPE viewmodule
    EXPORT_MACRO PLUGINDLLEXPORT_PRO
    SOURCES
        LocationViewStep.cpp
        LocationConfig.cpp
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
set(LOCATION_TARGET calamares_viewmodule_location)
if(NOT TARGET ${LOCATION_TARGET})
    message(FATAL_ERROR
        "calamares_add_plugin did not create ${LOCATION_TARGET}; upstream's target-naming "
        "convention has changed and the resource call below needs the new name")
endif()

# THE QML TRAVELS INSIDE THE .so, for the reason plan/21 §2 records: loading it by name out of the
# branding component directory or /usr/share/calamares/qml is a second install path and a second
# search order, and a page that renders blank if either is wrong, with nothing in the log. A
# resource cannot be half-installed.
qt6_add_resources(${LOCATION_TARGET} "location_qml"
    PREFIX "/location"
    FILES
        # The design system's tokens (plan/28). NOT in this directory in the repository —
        # config/calamares/qml/Theme.qml is the one copy, and scripts/stages/20-builder-setup.sh
        # stages it here for every module whose CMakeLists names it, which is this line.
        qml/Theme.qml
        # The design system's button and its labelled input, staged by the same fan-out (plan/29).
        # The page needs both once it can set the clock: a button opens the dialog, and the date
        # and time are typed into two Fields — which is also what keeps the dialog's two columns
        # from moving when a message appears under one of them.
        qml/Button.qml
        qml/Field.qml
        qml/Location.qml
)
