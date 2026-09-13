# SPDX-License-Identifier: GPL-3.0-or-later
#
# The Calamares view module for the greeting page (plan/23).
#
# Built OUT OF TREE against the installed Calamares, the same supported workflow the language and
# accounts modules use: CalamaresConfig.cmake exports Calamares::calamares and
# Calamares::calamaresui and puts Calamares' own CMakeModules on CMAKE_MODULE_PATH, so
# calamares_add_plugin() below is upstream's macro rather than a reimplementation. That matters
# because the macro is what writes module.desc, and a descriptor ModuleManager does not recognise
# is skipped in silence — which for THIS module means an installer that goes straight from the
# language list to the timezone page, with no requirement checks run at all.
cmake_minimum_required(VERSION 3.20)
project(calamares-greeting VERSION 1.0 LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Calamares REQUIRED)
# No Qml, Quick, QuickWidgets or QuickControls2, and that is the shape of this page rather than an
# omission: it is widgets all the way down (GreetingPage.h says why). Network is here because
# Requirements.cpp's internet check goes through Calamares::Network::Manager, which is
# libcalamares' wrapper over QNetworkAccessManager.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Network)

# KF6::CoreAddons is named in Calamares::calamares' INTERFACE_LINK_LIBRARIES, so linking against
# Calamares drags it in — but nothing DEFINES that imported target unless someone looks for it,
# and CalamaresConfig.cmake does not: its accumulate_deps() matches target prefixes against a
# lowercase "kf6::" while the targets are spelled "KF6::CoreAddons", CMake's MATCHES is
# case-sensitive, and the whole find_package(KF6) branch is therefore skipped. The failure lands
# here instead, at generate time, as "Target links to KF6::CoreAddons but the target was not
# found". Same finding as the sibling modules'; same one-line fix.
find_package(KF6CoreAddons REQUIRED)

# The plugin includes "Branding.h", "viewpages/ViewStep.h", "modulesystem/Requirement.h" and
# "widgets/WaitingWidget.h" by their in-tree paths, which is how every Calamares module spells
# them; Calamares_INCLUDE_DIRS is what makes those resolve from an installed prefix.
include_directories(${Calamares_INCLUDE_DIRS})

# THIS DIRECTORY, and it is not redundant. checker/ is upstream's layout, kept (plan/23 §2), and a
# quoted #include searches the INCLUDING file's directory first — so checker/ResultsListWidget.h
# asking for "GreetingConfig.h" looks in checker/ and finds nothing. calamares_add_plugin() does not
# supply it either: CalamaresAddLibrary.cmake calls include_directories(${CMAKE_CURRENT_LIST_DIR}),
# and inside a function body that variable is the directory of the .cmake file that DEFINED the
# function, not the one calling it.
include_directories(${CMAKE_CURRENT_SOURCE_DIR})

# greeting.conf, the packaged fallback, does not install itself. calamares_add_plugin() globs
# *.conf out of this directory and then guards the install on `if(INSTALL_CONFIG)` — an option
# Calamares' own top-level CMakeLists defines for its in-tree modules and CalamaresConfig.cmake
# does not export, so out of tree it is undefined and reads as false. Nothing warns: the glob DID
# find the file, so the macro also skips the "NO_CONFIG should be set." advice it prints for a
# plugin with no configuration at all.
#
# NOT `NO_CONFIG`, which would be the other way to silence the same glob: that stamps
# `noconfig: true` into module.desc and Calamares then never calls setConfigurationMap() — this
# module would run no checks at all and the page would sit on its spinner for ever.
set(INSTALL_CONFIG ON)

calamares_add_plugin(greeting
    TYPE viewmodule
    EXPORT_MACRO PLUGINDLLEXPORT_PRO
    SOURCES
        GreetingViewStep.cpp
        GreetingConfig.cpp
        GreetingPage.cpp
        Requirements.cpp
        checker/CheckerContainer.cpp
        checker/ResultsListWidget.cpp
        checker/ResultDelegate.cpp
    LINK_LIBRARIES
        Calamares::calamares
        Calamares::calamaresui
        Qt6::Gui
        Qt6::Widgets
        Qt6::Network
    SHARED_LIB
)
