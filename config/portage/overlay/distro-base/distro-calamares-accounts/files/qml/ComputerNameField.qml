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
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: field

    Kirigami.FormData.label: qsTr("Computer name:")

    spacing: 0

    QQC2.TextField {
        id: input
        Layout.fillWidth: true
        text: accounts.hostname
        onTextEdited: accounts.hostname = text
    }

    QQC2.Label {
        Layout.fillWidth: true
        visible: accounts.hostnameMessage.length > 0
        text: accounts.hostnameMessage
        wrapMode: Text.WordWrap
        color: Kirigami.Theme.negativeTextColor
        font: Kirigami.Theme.smallFont
    }
}
