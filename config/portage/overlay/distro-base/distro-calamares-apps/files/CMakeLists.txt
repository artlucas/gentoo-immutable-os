# SPDX-License-Identifier: GPL-3.0-or-later
#
# The Calamares view module for the applications page (plan/25).
#
# Built OUT OF TREE against the installed Calamares, the same supported workflow the other four
# modules use: CalamaresConfig.cmake exports Calamares::calamares and Calamares::calamaresui and
# puts Calamares' own CMakeModules on CMAKE_MODULE_PATH, so calamares_add_plugin() below is
# upstream's macro rather than a reimplementation. The macro is what writes module.desc, and a
# descriptor ModuleManager does not recognise is skipped in silence — which for THIS module means
# an installer that never asks which applications to add and never updates the ones it ships,
# because the job that does both reads an answer this page never wrote.
cmake_minimum_required(VERSION 3.20)
project(calamares-apps VERSION 1.0 LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Calamares REQUIRED)
# Network alongside the QML components: the page asks Calamares' own Network::Manager whether
# there is internet (network/Manager.h), and Manager's headers reach for QNetwork types that the
# link has to satisfy even though this plugin never includes them by name.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Network Qml Quick QuickWidgets QuickControls2)

# KF6::CoreAddons is named in Calamares::calamares' INTERFACE_LINK_LIBRARIES, so linking against
# Calamares drags it in — but nothing DEFINES that imported target unless someone looks for it,
# and CalamaresConfig.cmake does not: its accumulate_deps() matches target prefixes against a
# lowercase "kf6::" while the targets are spelled "KF6::CoreAddons", CMake's MATCHES is
# case-sensitive, and the whole find_package(KF6) branch is skipped. The failure lands here
# instead, at generate time. Fourth module, same one-line fix; see the sibling CMakeLists for the
# full finding.
find_package(KF6CoreAddons REQUIRED)

# The plugin includes "GlobalStorage.h", "Branding.h" and "viewpages/ViewStep.h" by their in-tree
# paths, which is how every Calamares module spells them; Calamares_INCLUDE_DIRS is what makes
# those resolve from an installed prefix.
include_directories(${Calamares_INCLUDE_DIRS})

# apps.conf, the packaged fallback, does not install itself: calamares_add_plugin() globs *.conf
# out of this directory and guards the install on `if(INSTALL_CONFIG)`, an option Calamares' own
# top-level CMakeLists defines for its in-tree modules and CalamaresConfig.cmake does not export —
# so out of tree it is undefined and reads as false, silently. The medium always gets the
# RENDERED /etc/calamares/modules/apps.conf; the packaged copy exists so the module is loadable on
# its own.
#
# NOT `NO_CONFIG`, which would be the other way to silence the same glob: that stamps
# `noconfig: true` into module.desc and Calamares then never calls setConfigurationMap(), so the
# page would come up with no app list and every choice would install nothing.
set(INSTALL_CONFIG ON)

calamares_add_plugin(apps
    TYPE viewmodule
    EXPORT_MACRO PLUGINDLLEXPORT_PRO
    SOURCES
        AppsViewStep.cpp
        AppsConfig.cpp
    LINK_LIBRARIES
        Calamares::calamares
        Calamares::calamaresui
        Qt6::Gui
        Qt6::Widgets
        Qt6::Network
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
set(APPS_TARGET calamares_viewmodule_apps)
if(NOT TARGET ${APPS_TARGET})
    message(FATAL_ERROR
        "calamares_add_plugin did not create ${APPS_TARGET}; upstream's target-naming convention "
        "has changed and the resource call below needs the new name")
endif()

# THE QML TRAVELS INSIDE THE .so, for the reason plan/21 §2 records: loading it by name out of the
# branding component directory or /usr/share/calamares/qml is a second install path and a second
# search order, and a page that renders blank if either is wrong, with nothing in the log. A
# resource cannot be half-installed.
qt6_add_resources(${APPS_TARGET} "apps_qml"
    PREFIX "/apps"
    FILES
        qml/Apps.qml
)
