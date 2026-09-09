# SPDX-License-Identifier: GPL-3.0-or-later
#
# The Calamares view module for managed enrolment (plan/19 §7.3, Phase D).
#
# Built OUT OF TREE against the installed Calamares, which is a workflow Calamares supports on
# purpose: CalamaresConfig.cmake exports the Calamares::calamares and Calamares::calamaresui
# targets and puts its own CMakeModules on CMAKE_MODULE_PATH, so calamares_add_plugin() below is
# upstream's own macro rather than a reimplementation of it. That matters more here than it
# looks: the macro is what writes the module.desc, and a module whose descriptor does not match
# what ModuleManager expects is silently skipped — no error, the step just never appears.
cmake_minimum_required(VERSION 3.20)
project(calamares-managed VERSION 1.0 LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Calamares REQUIRED)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets)

# KF6::CoreAddons is named in Calamares::calamares' INTERFACE_LINK_LIBRARIES, so linking against
# Calamares drags it in — but nothing defines that imported target unless someone looks for it,
# and CalamaresConfig.cmake does not. Its accumulate_deps() collects KF components by matching
# the target prefix against "${kfname}::", with kfname set to the lowercase "kf6", while the
# targets are spelled "KF6::CoreAddons". CMake's MATCHES is case-sensitive, so the match never
# fires, kf_required stays empty, and the whole find_package(KF6) branch below it is skipped.
# The failure lands here rather than there: "Target links to KF6::CoreAddons but the target was
# not found" at generate time. Found by configuring this module against the real installed
# 3.4.2, and fixed by asking for the framework directly.
#
# KF6CoreAddons, not KF6 COMPONENTS CoreAddons: the umbrella FindKF6.cmake is an ECM find-module
# and would make extra-cmake-modules a build dependency of this package for no other reason,
# whereas KF6CoreAddonsConfig.cmake ships with kcoreaddons itself.
find_package(KF6CoreAddons REQUIRED)

# The plugin includes "GlobalStorage.h" and "viewpages/ViewStep.h" by their in-tree paths, which
# is how every Calamares module spells them; Calamares_INCLUDE_DIRS is what makes those resolve
# from an installed prefix.
include_directories(${Calamares_INCLUDE_DIRS})

calamares_add_plugin(managed
    TYPE viewmodule
    EXPORT_MACRO PLUGINDLLEXPORT_PRO
    SOURCES
        ManagedViewStep.cpp
        ManagedPage.cpp
    LINK_LIBRARIES
        Calamares::calamares
        Calamares::calamaresui
        Qt6::Widgets
    SHARED_LIB
)
