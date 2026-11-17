import qs.modules.common
import qs.modules.common.widgets
import qs.services
import qs
import qs.modules.common.functions

import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris
import Quickshell.Hyprland

Item {
    id: root
    property bool borderless: Config.options.bar.borderless
    readonly property MprisPlayer activePlayer: MprisController.activePlayer

    readonly property bool usingMiu: MiuMusic.connected && MiuMusic.currentTrack !== null
    readonly property bool mprisPlaying: activePlayer?.isPlaying ?? false
    readonly property string cleanedTitle: usingMiu
        ? StringUtils.cleanMusicTitle(MiuMusic.currentTrack?.title ?? "")
        : StringUtils.cleanMusicTitle(activePlayer?.trackTitle ?? "")
    readonly property bool active: (usingMiu || mprisPlaying) && cleanedTitle.length > 0
    readonly property string subtitle: usingMiu
        ? (MiuMusic.currentTrack?.requestedBy?.username
            ? Translation.tr("by %1").arg(MiuMusic.currentTrack.requestedBy.username)
            : (MiuMusic.currentTrack?.channelTitle ?? ""))
        : (activePlayer?.trackArtist ?? "")
    readonly property bool showPlaying: usingMiu ? MiuMusic.userPlaying : (activePlayer?.isPlaying ?? false)
    readonly property real progress: usingMiu
        ? (MiuMusic.duration > 0 ? MiuMusic.position / MiuMusic.duration : 0)
        : ((activePlayer?.position ?? 0) / (activePlayer?.length ?? 1))

    Layout.fillHeight: true
    visible: root.active
    implicitWidth: root.active ? (rowLayout.implicitWidth + rowLayout.spacing * 2) : 0
    implicitHeight: Appearance.sizes.barHeight

    Timer {
        running: !root.usingMiu && activePlayer?.playbackState == MprisPlaybackState.Playing
        interval: Config.options.resources.updateInterval
        repeat: true
        onTriggered: activePlayer.positionChanged()
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton | Qt.BackButton | Qt.ForwardButton | Qt.RightButton | Qt.LeftButton
        onPressed: (event) => {
            if (event.button === Qt.MiddleButton) {
                if (root.usingMiu) MiuMusic.toggleAlong();
                else activePlayer?.togglePlaying();
            } else if (event.button === Qt.BackButton) {
                if (!root.usingMiu) activePlayer?.previous();
            } else if (event.button === Qt.ForwardButton || event.button === Qt.RightButton) {
                if (!root.usingMiu) activePlayer?.next();
            } else if (event.button === Qt.LeftButton) {
                GlobalStates.mediaControlsOpen = !GlobalStates.mediaControlsOpen
            }
        }
    }

    RowLayout { // Real content
        id: rowLayout

        spacing: 4
        anchors.fill: parent

        ClippedFilledCircularProgress {
            id: mediaCircProg
            Layout.alignment: Qt.AlignVCenter
            lineWidth: Appearance.rounding.unsharpen
            value: root.progress
            implicitSize: 20
            colPrimary: Appearance.colors.colOnSecondaryContainer
            enableAnimation: false

            Item {
                anchors.centerIn: parent
                width: mediaCircProg.implicitSize
                height: mediaCircProg.implicitSize
                
                MaterialSymbol {
                    anchors.centerIn: parent
                    fill: 1
                    text: root.showPlaying ? "pause" : "music_note"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.m3colors.m3onSecondaryContainer
                }
            }
        }

        StyledText {
            visible: Config.options.bar.verbose
            width: rowLayout.width - (CircularProgress.size + rowLayout.spacing * 2)
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: true // Ensures the text takes up available space
            Layout.rightMargin: rowLayout.spacing
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight // Truncates the text on the right
            color: Appearance.colors.colOnLayer1
            text: `${cleanedTitle}${subtitle ? ' • ' + subtitle : ''}`
        }

    }

}
