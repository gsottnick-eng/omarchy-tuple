import QtQuick

// Two overlapping rings: one per person on the call. The mark fills in when
// a call is live, dims when Tuple is not running, and carries a badge when
// the client needs attention (signed out, or an install waiting to happen).
Item {
  id: root

  property real iconSize: 16
  property color color: "white"
  property color badgeColor: "red"
  property bool filled: false
  property bool crossed: false
  property bool warning: false

  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real ring: Math.max(6, iconSize * 0.66)
  readonly property real stroke: Math.max(1, Math.round(iconSize * 0.1))
  readonly property real overlap: ring * 0.42

  Item {
    id: mark
    width: root.ring * 2 - root.overlap
    height: root.ring
    anchors.centerIn: parent

    Rectangle {
      width: root.ring
      height: root.ring
      radius: width / 2
      anchors.left: parent.left
      color: root.filled ? root.color : "transparent"
      border.color: root.color
      border.width: root.stroke
      opacity: root.filled ? 0.9 : 1.0
    }

    Rectangle {
      width: root.ring
      height: root.ring
      radius: width / 2
      anchors.right: parent.right
      color: root.filled ? root.color : "transparent"
      border.color: root.color
      border.width: root.stroke
      opacity: root.filled ? 0.55 : 1.0
    }
  }

  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: root.iconSize * 1.05
    height: root.stroke
    radius: height / 2
    rotation: -45
    color: root.color
  }

  Rectangle {
    visible: root.warning
    width: Math.max(4, root.iconSize * 0.3)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.top: parent.top
  }
}
