import QtQuick
import QtQuick.Effects
import qs.modules.common

Item {
    id: root
    required property var target
    property real radius: target.radius
    property real blur: 0.9 * Appearance.sizes.elevationMargin
    property var offset: Qt.vector2d(0.0, 1.0)
    property real spread: 1
    property color color: Appearance.colors.colShadow
    property bool cached: true
    anchors.fill: target

    Rectangle {
        id: shadowSource
        anchors.fill: parent
        radius: root.radius
        color: root.color
        visible: false
        layer.enabled: true
    }
    MultiEffect {
        anchors.fill: parent
        source: shadowSource
        blurEnabled: true
        blur: 1.0
        blurMax: Math.max(2, Math.round(root.blur))
        autoPaddingEnabled: true
        opacity: 0.9
    }
}
