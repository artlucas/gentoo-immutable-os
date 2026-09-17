/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * One field, in all three modes, and that is the point of it being a file.
 *
 * It is the hostname — GlobalStorage `hostname`, which `imagedeploy` writes to /etc/hostname as
 * soon as the /etc overlay is mounted and which `imageidentity` reads to decide whether to stamp
 * out the first-boot hostname unit. In managed mode it is ALSO the device name the control plane
 * shows, and in domain mode it is the default for the computer account's name. The page this one
 * replaces had two of these — the users page's hostname and the managed page's "Name for this
 * computer" — with nothing reconciling them.
 *
 * Since plan/28 it is a thin wrapper over the shared Field: mono, because a host name is an
 * identifier and the design system sets identifiers in the mono face. The wrapper survives the
 * repaint because what it is for was never the markup — it is the one place three forms agree
 * about one GlobalStorage key.
 */
import QtQuick
import QtQuick.Layouts

Field {
    id: field

    label: accounts.computerNameLabel
    text: accounts.hostname
    error: accounts.hostnameMessage
    mono: true
    onEdited: function (value) { accounts.hostname = value; }
}
