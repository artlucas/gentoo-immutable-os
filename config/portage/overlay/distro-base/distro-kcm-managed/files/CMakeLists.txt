# SPDX-License-Identifier: GPL-2.0-or-later
#
# The System Settings module for managed mode (plan/19 §7.2, Phase D).
#
# Nothing here is unusual, and that is the point: it is an ordinary KF6 QML KCM, built by
# Portage against the exact dev-qt/* and kde-frameworks/* versions the profile lock pins. The
# alternative plan/18 §7.2 rejected — hand-compiling a plugin in a build stage — would build it
# against whatever headers happened to be present, and an ABI mismatch in a Qt plugin does not
# fail to build, it fails to LOAD, silently, on a machine that cannot install a fix.
cmake_minimum_required(VERSION 3.20)
project(kcm-managed VERSION 1.0 LANGUAGES CXX)

set(QT_MIN_VERSION 6.7.0)
set(KF_MIN_VERSION 6.9.0)

find_package(ECM ${KF_MIN_VERSION} REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)

find_package(Qt6 ${QT_MIN_VERSION} REQUIRED COMPONENTS Core Gui Qml Quick)
find_package(KF6 ${KF_MIN_VERSION} REQUIRED COMPONENTS CoreAddons I18n KCMUtils)

# DISTRO_ID reaches the code as a compile definition rather than as a token substituted into the
# source. The ebuild passes it; the sources stay compilable, lintable and openable on their own.
if(NOT DEFINED DISTRO_ID)
    message(FATAL_ERROR "DISTRO_ID must be set (-DDISTRO_ID=...): the module execs <id>-managed")
endif()

# kcmutils_add_qml_kcm does three things at once, and all three are load-bearing: it builds the
# plugin into plasma/kcms/systemsettings (which is where System Settings looks and nowhere else),
# it compiles everything under ui/ into the plugin's own qrc so the QML travels inside the .so,
# and it generates the .desktop alias that makes the module findable by search rather than only
# by browsing. Losing the last one is the difference between "not in System Settings" and "in
# System Settings but nobody can find it".
kcmutils_add_qml_kcm(kcm_managed SOURCES ManagedKcm.cpp)

target_compile_definitions(kcm_managed PRIVATE DISTRO_ID="${DISTRO_ID}")

target_link_libraries(kcm_managed PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    KF6::CoreAddons
    KF6::I18n
    KF6::KCMUtilsQuick
)
