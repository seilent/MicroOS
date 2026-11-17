import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    property real padding: 10
    property var track: MiuMusic.currentTrack

    PagePlaceholder {
        shown: (root?.track ?? null) === null
        icon: "music_note"
        title: MiuMusic.connected ? Translation.tr("Nothing playing") : Translation.tr("Connecting…")
        description: MiuMusic.connected
            ? Translation.tr("Request a song in Discord to start the music player.")
            : Translation.tr("Waiting for the MIU server feed.")
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root?.padding ?? 10
        spacing: 12
        visible: (root?.track ?? null) !== null

        Rectangle {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
            implicitHeight: width
            radius: Appearance.rounding.normal
            color: ColorUtils.transparentize(Appearance.colors.colLayer2, 0.5)
            clip: true

            StyledImage {
                id: albumArt
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                cache: false
                antialiasing: true
                source: root?.track?.thumbnail ?? ""
                fallbacks: root?.track?.youtubeId
                    ? [`https://img.youtube.com/vi/${root.track.youtubeId}/hqdefault.jpg`]
                    : []

                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle {
                        width: albumArt.width
                        height: albumArt.height
                        radius: Appearance.rounding.normal
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            font.pixelSize: Appearance.font.pixelSize.large
            color: Appearance.colors.colOnLayer1
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.Wrap
            text: root?.track?.title ?? Translation.tr("Unknown Track")
        }

        StyledText {
            Layout.fillWidth: true
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            elide: Text.ElideRight
            text: {
                const requester = root?.track?.requestedBy?.username;
                const channel = root?.track?.channelTitle;
                if (requester && channel)
                    return `${channel} · ${Translation.tr("by")} ${requester}`;
                return channel ?? (requester ? `${Translation.tr("by")} ${requester}` : "");
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
            spacing: 10

            RippleButton {
                id: playPauseButton
                property real size: 44
                implicitWidth: size
                implicitHeight: size
                buttonRadius: MiuMusic.userPlaying ? Appearance.rounding.normal : size / 2
                colBackground: MiuMusic.userPlaying ? (Appearance.colors.colPrimary) : Appearance.colors.colSecondaryContainer
                colBackgroundHover: Appearance.colors.colSecondaryContainerHover
                colRipple: Appearance.colors.colSecondaryContainerActive
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

            MaterialSymbol {
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

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 4
            spacing: 4
            visible: MiuMusic.queue.length > 0

            StyledText {
                text: Translation.tr("Up next")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
            }

            ListView {
                id: queueList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 8
                model: MiuMusic.queue
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: StyledScrollBar {}

                delegate: RowLayout {
                    width: queueList.width
                    spacing: 10

                    Rectangle {
                        implicitWidth: 52
                        implicitHeight: 52
                        radius: Appearance.rounding.small
                        color: ColorUtils.transparentize(Appearance.colors.colLayer2, 0.5)
                        clip: true

                        StyledImage {
                            id: qArt
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectCrop
                            source: modelData?.thumbnail ?? ""
                            layer.enabled: true
                            layer.effect: OpacityMask {
                                maskSource: Rectangle {
                                    width: qArt.width
                                    height: qArt.height
                                    radius: Appearance.rounding.small
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 1

                        StyledText {
                            Layout.fillWidth: true
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colOnLayer1
                            elide: Text.ElideRight
                            maximumLineCount: 2
                            wrapMode: Text.Wrap
                            text: modelData?.title ?? ""
                        }
                        StyledText {
                            Layout.fillWidth: true
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                            text: modelData?.requestedBy?.username
                                ? Translation.tr("by %1").arg(modelData.requestedBy.username)
                                : (modelData?.channelTitle ?? "")
                        }
                    }
                }
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
                text: MiuMusic.connected
                    ? (MiuMusic.serverPlaying ? Translation.tr("Live") : Translation.tr("Paused on server"))
                    : Translation.tr("Disconnected")
            }
        }
    }
}
