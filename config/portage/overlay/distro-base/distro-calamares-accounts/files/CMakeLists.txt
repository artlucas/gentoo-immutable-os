# SPDX-License-Identifier: GPL-3.0-or-later
#
# The Calamares view module for the accounts page (plan/21).
#
# Built OUT OF TREE against the installed Calamares, which is a workflow Calamares supports on
# purpose: CalamaresConfig.cmake exports the Calamares::calamares and Calamares::calamaresui
# targets and puts its own CMakeModules on CMAKE_MODULE_PATH, so calamares_add_plugin() below is
# upstream's own macro rather than a reimplementation of it. That matters more here than it
# looks: the macro is what writes the module.desc, and a module whose descriptor does not match
# what ModuleManager expects is silently skipped — no error, the step just never appears.
cmake_minimum_required(VERSION 3.20)
project(calamares-accounts VERSION 1.0 LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Calamares REQUIRED)
# Quick, Qml and QuickWidgets on top of the predecessor module's Widgets: this page's UI is QML
# hosted in a QQuickWidget (plan/21 §2). None of the three is a new requirement on the IMAGE —
# CalamaresConfig.cmake already re-finds Qt6 with the components accumulated from Calamares' own
# imported targets, and Calamares links QuickWidgets for its own *q modules, so a Calamares that
# resolves at all resolves these.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Qml Quick QuickWidgets QuickControls2)

# KF6::CoreAddons is named in Calamares::calamares' INTERFACE_LINK_LIBRARIES, so linking against
# Calamares drags it in — but nothing defines that imported target unless someone looks for it,
# and CalamaresConfig.cmake does not. Its accumulate_deps() collects KF components by matching
# the target prefix against "${kfname}::", with kfname set to the lowercase "kf6", while the
# targets are spelled "KF6::CoreAddons". CMake's MATCHES is case-sensitive, so the match never
# fires, kf_required stays empty, and the whole find_package(KF6) branch below it is skipped.
# The failure lands here rather than there: "Target links to KF6::CoreAddons but the target was
# not found" at generate time. Found by configuring the predecessor module against the real
# installed 3.4.2, and fixed by asking for the framework directly.
#
# KF6CoreAddons, not KF6 COMPONENTS CoreAddons: the umbrella FindKF6.cmake is an ECM find-module
# and would make extra-cmake-modules a build dependency of this package for no other reason,
# whereas KF6CoreAddonsConfig.cmake ships with kcoreaddons itself.
find_package(KF6CoreAddons REQUIRED)

# libpwquality by pkg-config, because that is the only interface it exports — there is no
# LibPWQualityConfig.cmake in the tree. This is the SAME library Calamares' own users page uses
# (dev-libs/libpwquality[python] is in package.use/image for exactly that reason), so the meter
# on this page and the rule it enforces are one implementation, and stage 40's cracklib
# dictionary keeps backing both.
find_package(PkgConfig REQUIRED)
pkg_check_modules(PWQUALITY REQUIRED IMPORTED_TARGET pwquality)

# The plugin includes "GlobalStorage.h" and "viewpages/ViewStep.h" by their in-tree paths, which
# is how every Calamares module spells them; Calamares_INCLUDE_DIRS is what makes those resolve
# from an installed prefix.
include_directories(${Calamares_INCLUDE_DIRS})

# DISTRO_ID reaches the code as a compile definition rather than as a token substituted into the
# source. The ebuild passes it; the sources stay compilable, lintable and openable on their own.
# This page execs <id>-managed and <id>-domain, so it cannot be built without one.
if(NOT DEFINED DISTRO_ID)
    message(FATAL_ERROR "DISTRO_ID must be set (-DDISTRO_ID=...): the page execs <id>-managed")
endif()

# accounts.conf, the packaged fallback, does not install itself. calamares_add_plugin() globs
# *.conf out of this directory and then guards the install on `if(INSTALL_CONFIG)` — an option
# Calamares' own top-level CMakeLists defines and CalamaresConfig.cmake does not export, so it
# is simply undefined here and reads as false. Nothing warns: the glob found the file, so the
# macro does not print its "NO_CONFIG should be set." advice either, and the module installs
# with no default configuration at all.
#
# Measured on the built target root, not read off the macro: /usr/share/calamares/modules/ held
# no accounts.conf after a full emerge. The medium never noticed, because stage 40 renders
# /etc/calamares/modules/accounts.conf and /etc is searched first — but a module whose only
# configuration is one an unrelated stage writes is not loadable on its own, which is the one
# thing the packaged copy exists for.
#
# NOT `NO_CONFIG`, which would be the other way to silence the same glob: that stamps
# `noconfig: true` into module.desc, and Calamares then never calls setConfigurationMap() at
# all. The page would come up with no modes offered and no groups — an empty screen.
set(INSTALL_CONFIG ON)

calamares_add_plugin(accounts
    TYPE viewmodule
    EXPORT_MACRO PLUGINDLLEXPORT_PRO
    SOURCES
        AccountsViewStep.cpp
        AccountsConfig.cpp
        PasswordCheck.cpp
    LINK_LIBRARIES
        Calamares::calamares
        Calamares::calamaresui
        Qt6::Widgets
        Qt6::Qml
        Qt6::Quick
        Qt6::QuickWidgets
        Qt6::QuickControls2
        PkgConfig::PWQUALITY
    SHARED_LIB
)

# The target name is calamares_add_plugin's, not ours: CalamaresAddPlugin.cmake builds it as
# "calamares_${TYPE}_${NAME}". Asserting it rather than assuming it means an upstream rename
# fails HERE, with this message, instead of at the qt6_add_resources call below with CMake's own
# "add_library called with incorrect number of arguments".
set(ACCOUNTS_TARGET calamares_viewmodule_accounts)
if(NOT TARGET ${ACCOUNTS_TARGET})
    message(FATAL_ERROR
        "calamares_add_plugin did not create ${ACCOUNTS_TARGET}; upstream's target-naming "
        "convention has changed and the resource and definition calls below need the new name")
endif()

target_compile_definitions(${ACCOUNTS_TARGET} PRIVATE DISTRO_ID="${DISTRO_ID}")

# THE QML TRAVELS INSIDE THE .so. Calamares::QmlViewStep would load it by name out of the
# branding component directory or /usr/share/calamares/qml — a second install path, a second
# search order, and a page that renders blank if either is wrong, with nothing in the log. A
# resource cannot be half-installed. See plan/21 §2.
qt6_add_resources(${ACCOUNTS_TARGET} "accounts_qml"
    PREFIX "/accounts"
    FILES
        qml/Accounts.qml
        qml/ComputerNameField.qml
        qml/LocalForm.qml
        qml/ManagedForm.qml
        qml/DomainForm.qml
)
