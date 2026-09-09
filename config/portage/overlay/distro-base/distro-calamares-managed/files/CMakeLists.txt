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
