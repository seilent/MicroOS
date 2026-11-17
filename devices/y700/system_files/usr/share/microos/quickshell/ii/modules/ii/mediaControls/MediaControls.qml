pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root
    property real widgetWidth: Appearance.sizes.mediaControlsWidth
    property real popupRounding: Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1
    readonly property var track: MiuMusic.currentTrack
    readonly property bool hasTrack: (MiuMusic.currentTrack ?? null) !== null

    Loader {
        id: mediaControlsLoader
        active: GlobalStates.mediaControlsOpen

        sourceComponent: PanelWindow {
            id: panelWindow
            visible: true

            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            implicitWidth: root.widgetWidth
            implicitHeight: card.implicitHeight + Appearance.sizes.elevationMargin * 2
            color: "transparent"
            WlrLayershell.namespace: "quickshell:mediaControls"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

            anchors {
                top: !Config.options.bar.bottom || Config.options.bar.vertical
                bottom: Config.options.bar.bottom && !Config.options.bar.vertical
                left: !(Config.options.bar.vertical && Config.options.bar.bottom)
                right: Config.options.bar.vertical && Config.options.bar.bottom
            }
            margins {
                top: Appearance.sizes.barHeight
                bottom: Appearance.sizes.barHeight
                left: Config.options.bar.vertical ? Appearance.sizes.barHeight : ((panelWindow.screen.width / 2) - (root.widgetWidth / 2) - 230)
                right: Appearance.sizes.barHeight
            }

            mask: Region {
                item: card
            }

            Component.onCompleted: GlobalFocusGrab.addDismissable(panelWindow)
            Component.onDestruction: GlobalFocusGrab.removeDismissable(panelWindow)
            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    GlobalStates.mediaControlsOpen = false;
                }
            }

            StyledRectangularShadow {
                target: card
            }

            Rectangle {
                id: card
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: Appearance.sizes.elevationMargin
                width: root.widgetWidth - Appearance.sizes.elevationMargin * 2
                implicitHeight: contentColumn.implicitHeight + 26
                color: Appearance.colors.colLayer0
                radius: root.popupRounding

                property bool settingsOpen: false

                ColumnLayout {
                    id: contentColumn
                    anchors.fill: parent
                    anchors.margins: 13
                    spacing: 12

                    RowLayout {
                            Layout.fillWidth: true
                            spacing: 13

                            Rectangle {
                                implicitWidth: 72
                                implicitHeight: 72
                                radius: Appearance.rounding.small
                                color: ColorUtils.transparentize(Appearance.colors.colLayer1, 0.5)
                                clip: true

                                StyledImage {
                                    id: art
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectCrop
                                    cache: false
                                    antialiasing: true
                                    source: root.track?.thumbnail ?? ""
                                    fallbacks: root.track?.youtubeId
                                        ? [`https://img.youtube.com/vi/${root.track.youtubeId}/hqdefault.jpg`]
                                        : []
                                    layer.enabled: true
                                    layer.effect: OpacityMask {
                                        maskSource: Rectangle {
                                            width: art.width
                                            height: art.height
                                            radius: Appearance.rounding.small
                                        }
                                    }
                                }

                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    visible: !root.hasTrack
                                    text: "music_note"
                                    iconSize: 32
                                    color: Appearance.colors.colSubtext
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 2

                                StyledText {
                                    Layout.fillWidth: true
                                    font.pixelSize: Appearance.font.pixelSize.large
                                    color: Appearance.colors.colOnLayer0
                                    elide: Text.ElideRight
                                    maximumLineCount: 2
                                    wrapMode: Text.Wrap
                                    text: root.hasTrack
                                        ? (root.track?.title ?? Translation.tr("Unknown Track"))
                                        : (MiuMusic.connected ? Translation.tr("Nothing playing") : Translation.tr("Connecting…"))
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colSubtext
                                    elide: Text.ElideRight
                                    text: {
                                        const requester = root.track?.requestedBy?.username;
                                        const channel = root.track?.channelTitle;
                                        if (requester && channel)
                                            return `${channel} · ${Translation.tr("by")} ${requester}`;
                                        return channel ?? (requester ? `${Translation.tr("by")} ${requester}` : "");
                                    }
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            StyledProgressBar {
                                Layout.fillWidth: true
                                highlightColor: Appearance.colors.colPrimary
                                trackColor: Appearance.colors.colSecondaryContainer
                                wavy: MiuMusic.serverPlaying
                                value: MiuMusic.duration > 0 ? Math.min(MiuMusic.position / MiuMusic.duration, 1) : 0
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                StyledText {
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colSubtext
                                    text: StringUtils.friendlyTimeForSeconds(MiuMusic.position)
                                }
                                Item { Layout.fillWidth: true }
                                StyledText {
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colSubtext
                                    text: StringUtils.friendlyTimeForSeconds(MiuMusic.duration)
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            RippleButton {
                                property real size: 44
                                implicitWidth: size
                                implicitHeight: size
                                buttonRadius: MiuMusic.userPlaying ? Appearance.rounding.normal : size / 2
                                colBackground: MiuMusic.userPlaying ? Appearance.colors.colPrimary : Appearance.colors.colSecondaryContainer
                                colBackgroundHover: MiuMusic.userPlaying ? Appearance.colors.colPrimaryHover : Appearance.colors.colSecondaryContainerHover
                                colRipple: MiuMusic.userPlaying ? Appearance.colors.colPrimaryActive : Appearance.colors.colSecondaryContainerActive
                                downAction: () => MiuMusic.toggleAlong()
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    iconSize: Appearance.font.pixelSize.huge
                                    fill: 1
                                    horizontalAlignment: Text.AlignHCenter
                                    color: MiuMusic.userPlaying ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSecondaryContainer
                                    text: MiuMusic.userPlaying ? "pause" : "play_arrow"
                                }
                            }

                            RippleButton {
                                property real size: 40
                                implicitWidth: size
                                implicitHeight: size
                                enabled: MiuMusic.canControl && root.hasTrack
                                opacity: enabled ? 1 : 0.4
                                buttonRadius: size / 2
                                colBackground: Appearance.colors.colSecondaryContainer
                                colBackgroundHover: Appearance.colors.colSecondaryContainerHover
                                colRipple: Appearance.colors.colSecondaryContainerActive
                                downAction: () => MiuMusic.skip()
                                StyledToolTip { text: Translation.tr("Skip") }
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    iconSize: Appearance.font.pixelSize.larger
                                    fill: 1
                                    horizontalAlignment: Text.AlignHCenter
                                    color: Appearance.colors.colOnSecondaryContainer
                                    text: "skip_next"
                                }
                            }

                            RippleButton {
                                property real size: 40
                                implicitWidth: size
                                implicitHeight: size
                                enabled: MiuMusic.canControl && root.hasTrack
                                opacity: enabled ? 1 : 0.4
                                buttonRadius: size / 2
                                colBackground: Appearance.colors.colSecondaryContainer
                                colBackgroundHover: Appearance.m3colors.m3errorContainer
                                colRipple: Appearance.m3colors.m3error
                                downAction: () => MiuMusic.ban()
                                StyledToolTip { text: Translation.tr("Ban this track") }
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    iconSize: Appearance.font.pixelSize.larger
                                    fill: 1
                                    horizontalAlignment: Text.AlignHCenter
                                    color: Appearance.colors.colOnSecondaryContainer
                                    text: "block"
                                }
                            }

                            MaterialSymbol {
                                Layout.leftMargin: 6
                                iconSize: Appearance.font.pixelSize.larger
                                color: Appearance.colors.colSubtext
                                text: MiuMusic.volume <= 0 ? "volume_off"
                                    : MiuMusic.volume < 0.5 ? "volume_down" : "volume_up"
                            }

                            StyledSlider {
                                Layout.fillWidth: true
                                configuration: StyledSlider.Configuration.S
                                highlightColor: Appearance.colors.colPrimary
                                trackColor: Appearance.colors.colSecondaryContainer
                                handleColor: Appearance.colors.colPrimary
                                value: MiuMusic.volume
                                onMoved: MiuMusic.setVolume(value)
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Rectangle {
                                implicitWidth: 8
                                implicitHeight: 8
                                radius: 4
                                color: MiuMusic.connected ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                            }
                            StyledText {
                                Layout.fillWidth: true
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                                elide: Text.ElideRight
                                text: !MiuMusic.connected ? Translation.tr("Disconnected")
                                    : !MiuMusic.canControl ? Translation.tr("Set a token to skip / ban")
                                    : (MiuMusic.serverPlaying ? Translation.tr("Live") : Translation.tr("Paused on server"))
                            }

                            RippleButton {
                                property real size: 32
                                implicitWidth: size
                                implicitHeight: size
                                buttonRadius: size / 2
                                toggled: card.settingsOpen
                                colBackground: ColorUtils.transparentize(Appearance.colors.colSecondaryContainer, 1)
                                colBackgroundHover: Appearance.colors.colSecondaryContainerHover
                                colRipple: Appearance.colors.colSecondaryContainerActive
                                downAction: () => card.settingsOpen = !card.settingsOpen
                                StyledToolTip { text: Translation.tr("Token settings") }
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    iconSize: Appearance.font.pixelSize.larger
                                    fill: card.settingsOpen ? 1 : 0
                                    horizontalAlignment: Text.AlignHCenter
                                    color: card.settingsOpen ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
                                    text: "settings"
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            visible: card.settingsOpen
                            spacing: 8

                            MaterialTextField {
                                id: tokenField
                                Layout.fillWidth: true
                                echoMode: TextInput.Password
                                placeholderText: Translation.tr("Paste MIU token (JWT)")
                                text: Config.options.music.apiKey
                                onAccepted: Config.options.music.apiKey = text.trim()
                            }

                            RippleButton {
                                property real size: 38
                                implicitWidth: size
                                implicitHeight: size
                                buttonRadius: Appearance.rounding.small
                                colBackground: Appearance.colors.colPrimary
                                colBackgroundHover: Appearance.colors.colPrimaryHover
                                colRipple: Appearance.colors.colPrimaryActive
                                downAction: () => {
                                    Config.options.music.apiKey = tokenField.text.trim();
                                    card.settingsOpen = false;
                                }
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    iconSize: Appearance.font.pixelSize.larger
                                    fill: 1
                                    horizontalAlignment: Text.AlignHCenter
                                    color: Appearance.colors.colOnPrimary
                                    text: "check"
                                }
                            }
                        }
                    }
                }
            }
        }

    IpcHandler {
        target: "mediaControls"

        function toggle(): void {
            GlobalStates.mediaControlsOpen = !GlobalStates.mediaControlsOpen;
            if (GlobalStates.mediaControlsOpen)
                Notifications.timeoutAll();
        }

        function close(): void {
            GlobalStates.mediaControlsOpen = false;
        }

        function open(): void {
            GlobalStates.mediaControlsOpen = true;
            Notifications.timeoutAll();
        }
    }

    GlobalShortcut {
        name: "mediaControlsToggle"
        description: "Toggles media controls on press"
        onPressed: GlobalStates.mediaControlsOpen = !GlobalStates.mediaControlsOpen
    }
    GlobalShortcut {
        name: "mediaControlsOpen"
        description: "Opens media controls on press"
        onPressed: GlobalStates.mediaControlsOpen = true
    }
    GlobalShortcut {
        name: "mediaControlsClose"
        description: "Closes media controls on press"
        onPressed: GlobalStates.mediaControlsOpen = false
    }
    GlobalShortcut {
        name: "miuPlayPause"
        description: "Toggles MIU play/pause"
        onPressed: MiuMusic.toggleAlong()
    }
}
