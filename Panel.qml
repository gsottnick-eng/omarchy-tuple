import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Tuple in the Omarchy bar: install the client, sign in, call a teammate, hop
// into a room. This file is only the view; TupleStore owns the client, once
// for every monitor.
Panel {
  id: root
  moduleName: "io.github.gsottnick.tuple"
  ipcTarget: "io.github.gsottnick.tuple"
  // The handler below adds call verbs to open/close. Built once per monitor,
  // only the first registers; the rest log a warning, as first-party widgets do.
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, accent)

  readonly property bool ready: TupleStore.installed && TupleStore.loggedIn
  // Unverified against a real incoming call: a call this side did not start
  // that has not connected yet is treated as ringing.
  readonly property bool ringing: TupleStore.inCall && !TupleStore.connected && TupleStore.calling === ""
  readonly property var rooms: ready ? Model.visibleRooms(TupleStore.rooms, search) : []
  readonly property var people: ready ? Model.visibleContacts(TupleStore.contacts, search) : []
  property string search: ""

  property string focusSection: "header"
  property int roomIndex: 0
  property int personIndex: 0
  property bool cursorActive: false
  // PanelKeyCatcher claims plain letters, so it stands down while a text
  // field has focus.
  property int editorsFocused: 0

  readonly property string barText: {
    if (!Model.toBool(setting("showLabel", false), false)) return ""
    if (TupleStore.inCall) return TupleStore.sharing ? "Sharing" : (TupleStore.muted ? "Muted" : "In call")
    return TupleStore.loggedIn ? "" : "Tuple"
  }

  onSettingsChanged: TupleStore.callAlerts = Model.toBool(setting("callAlerts", true), true)
  Component.onCompleted: TupleStore.callAlerts = Model.toBool(setting("callAlerts", true), true)

  // ------------------------------------------------------------- keyboard

  function sectionOrder() {
    var order = ["header"]
    if (TupleStore.inCall) order.push("call")
    if (rooms.length > 0) order.push("rooms")
    if (people.length > 0) order.push("people")
    return order
  }

  function sectionList(section) {
    return section === "rooms" ? rooms : (section === "people" ? people : null)
  }

  function sectionLength(section) {
    var list = sectionList(section)
    return list ? list.length : 1
  }

  function sectionIndex(section) {
    return section === "rooms" ? roomIndex : (section === "people" ? personIndex : 0)
  }

  function setSectionIndex(section, value) {
    if (section === "rooms") roomIndex = value
    else if (section === "people") personIndex = value
  }

  function ensureCursor() {
    var order = sectionOrder()
    if (order.indexOf(focusSection) === -1) focusSection = order[0]
    var max = Math.max(0, sectionLength(focusSection) - 1)
    setSectionIndex(focusSection, Math.max(0, Math.min(sectionIndex(focusSection), max)))
  }

  function moveCursor(dy) {
    cursorActive = true
    ensureCursor()
    var order = sectionOrder()
    var at = order.indexOf(focusSection)
    var index = sectionIndex(focusSection)
    if (dy > 0) {
      if (index < sectionLength(focusSection) - 1) setSectionIndex(focusSection, index + 1)
      else if (at < order.length - 1) { focusSection = order[at + 1]; setSectionIndex(focusSection, 0) }
    } else if (dy < 0) {
      if (index > 0) setSectionIndex(focusSection, index - 1)
      else if (at > 0) { focusSection = order[at - 1]; setSectionIndex(focusSection, sectionLength(focusSection) - 1) }
    }
    scrollCursorIntoView()
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") {
      if (!TupleStore.installed) TupleStore.install()
      else if (!TupleStore.loggedIn) TupleStore.signIn()
    } else if (focusSection === "call") {
      if (root.ringing) TupleStore.accept()
      else TupleStore.toggleMute()
    } else if (focusSection === "rooms") {
      TupleStore.joinRoom(rooms[roomIndex])
    } else if (focusSection === "people") {
      TupleStore.callPerson(people[personIndex])
    }
  }

  function setCursor(section, index) {
    cursorActive = true
    focusSection = section
    setSectionIndex(section, index)
  }

  function scrollCursorIntoView() {
    var view = focusSection === "rooms" ? roomList : (focusSection === "people" ? peopleList : null)
    if (view) view.positionViewAtIndex(sectionIndex(focusSection), ListView.Contain)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    roomList.positionViewAtBeginning()
    peopleList.positionViewAtBeginning()
    if (!TupleStore.installed) TupleStore.probe()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onRoomsChanged: ensureCursor()
  onPeopleChanged: ensureCursor()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return TupleStore.summary }
    function mute(): string { TupleStore.toggleMute(); return "ok" }
    function share(): string { TupleStore.toggleShare(); return TupleStore.canShare ? "ok" : "unsupported" }
    function leave(): string { TupleStore.leave(); return "ok" }
    function accept(): string { TupleStore.accept(); return "ok" }
    function join(url: string): string { return TupleStore.joinUrl(url) ? "ok" : "invalid url" }
    function diagnose(): string { TupleStore.diagnose(); return "ok" }
  }

  // Sharing from the panel: close it first, so the portal picker never opens
  // underneath. The `s` key shares through this too; the IPC `share` verb has
  // no panel to close.
  function shareFromPanel(): void { root.close(); TupleStore.toggleShare() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    tooltipText: "Tuple: " + TupleStore.summary
    iconComponent: Component {
      Item {
        TupleIcon {
          anchors.centerIn: parent
          iconSize: Style.bar.iconCanvas
          color: root.ready ? root.barForeground : Qt.darker(root.barForeground, 1.55)
          badgeColor: root.urgent
          filled: TupleStore.inCall
          crossed: TupleStore.inCall && TupleStore.muted
          warning: !root.ready
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && TupleStore.inCall) TupleStore.toggleMute()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Signed in, the panel keeps one height and its content scrolls, so
    // searching never resizes it. Setup and sign-in fit their few lines.
    contentHeight: panel.fittedContentHeight(root.ready ? Style.space(620) : column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editorsFocused > 0
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "m") TupleStore.toggleMute()
        else if (key === "s") root.shareFromPanel()
        else if (key === "l") TupleStore.leave()
        else if (key === "a" && root.ringing) TupleStore.accept()
        else if (key === "/" && root.ready) searchField.forceActiveFocus()
      }

      // The panel itself does not scroll: each list scrolls on its own, and
      // People takes whatever height is left.
      Item {
        anchors.fill: parent
        clip: true

        ColumnLayout {
          id: column
          width: parent.width
          height: root.ready ? parent.height : implicitHeight
          spacing: Style.space(12)

          // ------------------------------------------------------- header
          PanelHero {
            id: hero
            Layout.fillWidth: true
            Layout.minimumHeight: implicitHeight
            title: TupleStore.user ? TupleStore.user.name : "Tuple"
            meta: TupleStore.summary
            detail: TupleStore.installed && TupleStore.loggedIn && !TupleStore.online ? "OFFLINE" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.ready ? 1.0 : 0.55
            iconComponent: Component {
              TupleIcon {
                iconSize: Style.font.display
                color: TupleStore.inCall ? root.accent : root.foreground
                badgeColor: root.urgent
                filled: TupleStore.inCall
                warning: !root.ready
              }
            }
            // Start/stop is the one control that works before sign in.
            trailingControl: Component {
              ToggleSwitch {
                id: daemonSwitch
                visible: TupleStore.installed
                checked: TupleStore.daemonRunning
                busy: TupleStore.busy
                hasCursor: root.cursorActive && root.focusSection === "header" && root.ready
                foreground: hero.foreground
                onToggled: TupleStore.daemonRunning ? TupleStore.stop() : TupleStore.start()

                PanelToolTip {
                  visible: daemonSwitch.containsMouse
                  text: TupleStore.daemonRunning ? "Stop Tuple" : "Start Tuple"
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          Text {
            visible: text !== ""
            Layout.fillWidth: true
            Layout.minimumHeight: implicitHeight
            text: TupleStore.error !== "" ? TupleStore.error : TupleStore.status
            color: TupleStore.error !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
          }

          // -------------------------------------------------------- setup
          Column {
            visible: TupleStore.probed && !TupleStore.installed
            Layout.fillWidth: true
            Layout.minimumHeight: implicitHeight
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: TupleStore.installing ? TupleStore.installMessage
                : "Tuple for Linux isn't installed. This downloads the official client, checks it against Tuple's published checksum, and puts it on your PATH."
              color: TupleStore.installing ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              text: TupleStore.installing ? "Installing…" : "Install Tuple"
              enabled: !TupleStore.installing
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.focusSection === "header"
              onClicked: TupleStore.install()
            }
          }

          // ------------------------------------------------------ sign in
          Column {
            visible: TupleStore.installed && TupleStore.daemonRunning && !TupleStore.loggedIn
            Layout.fillWidth: true
            Layout.minimumHeight: implicitHeight
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: TupleStore.loginUrl !== ""
                ? "Finish signing in in your browser, then paste the authorization code here."
                : "Sign in to Tuple to see your rooms and people."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              visible: TupleStore.loginUrl === ""
              text: TupleStore.loggingIn ? "Opening…" : "Sign in"
              enabled: !TupleStore.loggingIn
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.focusSection === "header"
              onClicked: TupleStore.signIn()
            }

            Row {
              visible: TupleStore.loginUrl !== ""
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: codeField
                onActiveFocusChanged: root.editorsFocused += activeFocus ? 1 : -1
                width: parent.width - finishButton.width - reopenButton.width - copyLinkButton.width - Style.space(18)
                foreground: root.foreground
                placeholderText: "Authorization code"
                onAccepted: if (TupleStore.submitCode(text)) text = ""
              }

              Button {
                id: finishButton
                text: "Finish"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (TupleStore.submitCode(codeField.text)) codeField.text = ""
              }

              PanelActionButton {
                id: reopenButton
                iconText: "\u{f059f}"
                tooltipText: "Open the sign-in page again"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: TupleStore.openLoginUrl()
              }

              PanelActionButton {
                id: copyLinkButton
                iconText: "\u{f018f}"
                tooltipText: "Copy the sign-in link"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: TupleStore.copy(TupleStore.loginUrl)
              }
            }
          }

          // --------------------------------------------------------- call
          PanelSeparator { Layout.fillWidth: true; Layout.minimumHeight: implicitHeight; visible: TupleStore.inCall || TupleStore.calling !== ""; foreground: root.foreground }

          Column {
            visible: TupleStore.inCall || TupleStore.calling !== ""
            Layout.fillWidth: true
            Layout.minimumHeight: implicitHeight
            spacing: Style.space(8)

            PanelSectionHeader {
              text: root.ringing ? "INCOMING CALL" : "CURRENT CALL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CursorSurface {
              width: parent.width
              hasCursor: root.cursorActive && root.focusSection === "call"
              foreground: root.foreground
              fill: root.hoverFill
              implicitHeight: callRow.implicitHeight + Style.spacing.rowPaddingX

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.setCursor("call", 0)
              }

              RowLayout {
                id: callRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    Layout.fillWidth: true
                    text: {
                      if (TupleStore.calling !== "") return "Calling " + TupleStore.calling + "…"
                      var names = TupleStore.participants.map(function(p) { return p.name })
                      return names.length > 0 ? names.join(", ") : "Waiting for others…"
                    }
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                  }

                  Text {
                    Layout.fillWidth: true
                    visible: TupleStore.inCall
                    text: (TupleStore.muted ? "Muted" : "Microphone on") + (TupleStore.sharing ? " · Sharing your screen" : "")
                    color: TupleStore.muted ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  visible: root.ringing
                  iconText: "\u{f03f2}"
                  tooltipText: "Answer (a)"
                  foreground: root.accent
                  fontFamily: root.fontFamily
                  onClicked: TupleStore.accept()
                }

                PanelActionButton {
                  visible: TupleStore.inCall
                  iconText: TupleStore.muted ? "\u{f036d}" : "\u{f036c}"
                  tooltipText: TupleStore.muted ? "Unmute (m)" : "Mute (m)"
                  foreground: TupleStore.muted ? root.urgent : root.foreground
                  fontFamily: root.fontFamily
                  onClicked: TupleStore.toggleMute()
                }

                PanelActionButton {
                  visible: TupleStore.inCall && TupleStore.canShare
                  iconText: TupleStore.sharing ? "\u{f0e59}" : "\u{f0379}"
                  tooltipText: TupleStore.sharing ? "Stop sharing (s)" : "Share your screen (s)"
                  foreground: TupleStore.sharing ? root.accent : root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.shareFromPanel()
                }

                PanelActionButton {
                  iconText: "\u{f073a}"
                  tooltipText: TupleStore.calling !== "" ? "Cancel (l)" : "Leave (l)"
                  foreground: root.foreground
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  onClicked: TupleStore.leave()
                }
              }
            }

            // Sharer-side settings, shown only while the client still offers
            // them; they apply to what others can do with the shared screen.
            ColumnLayout {
              visible: TupleStore.inCall && TupleStore.canSettings
              Layout.fillWidth: true
              Layout.minimumHeight: implicitHeight
              spacing: Style.space(4)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  text: "Let others draw on my screen"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                }

                ToggleSwitch {
                  checked: TupleStore.settings["overlay"] === "1"
                  busy: TupleStore.busy
                  foreground: root.foreground
                  onToggled: TupleStore.setSetting("overlay", checked ? "1" : "0")
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  text: "When viewing a screen: " + (TupleStore.settings["guest-mode"] === "control" ? "Control" : "Draw")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                }

                ToggleSwitch {
                  checked: TupleStore.settings["guest-mode"] === "control"
                  busy: TupleStore.busy
                  foreground: root.foreground
                  onToggled: TupleStore.setSetting("guest-mode", checked ? "control" : "annotation")
                }
              }
            }
          }

          // -------------------------------------------------------- rooms
          PanelSeparator { Layout.fillWidth: true; Layout.minimumHeight: implicitHeight; visible: root.ready; foreground: root.foreground }

          ColumnLayout {
            visible: root.ready
            Layout.fillWidth: true
            // Layouts only resize fillHeight items; the room list's own
            // maximum stops this section from growing past it.
            Layout.fillHeight: true
            spacing: Style.space(8)

            PanelSectionHeader {
              Layout.minimumHeight: implicitHeight
              text: "ROOMS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // One field: typing filters rooms and people, a pasted link joins on Enter.
            TextField {
              id: searchField
              Layout.fillWidth: true
              Layout.minimumHeight: implicitHeight
              onActiveFocusChanged: root.editorsFocused += activeFocus ? 1 : -1
              foreground: root.foreground
              placeholderText: "Search, or paste a link to join (/)"
              onTextChanged: root.search = text
              onAccepted: if (Model.isJoinableUrl(text) && TupleStore.joinUrl(text)) text = ""
            }

            Text {
              visible: root.rooms.length === 0
              Layout.fillWidth: true
              text: root.search !== "" ? "No rooms match." : "No rooms yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            // Your room, then favorites A to Z, then the rest: one list that
            // scrolls on its own, like People.
            RoomList {
              id: roomList
              model: root.rooms
            }
          }

          // ------------------------------------------------------- people
          PanelSeparator { Layout.fillWidth: true; Layout.minimumHeight: implicitHeight; visible: root.ready; foreground: root.foreground }

          ColumnLayout {
            visible: root.ready
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(8)

            PanelSectionHeader {
              Layout.minimumHeight: implicitHeight
              text: "PEOPLE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.people.length === 0
              Layout.fillWidth: true
              text: root.search !== "" ? "Nobody matches." : "No contacts yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            ListView {
              id: peopleList
              Layout.fillWidth: true
              Layout.fillHeight: true
              // Asks for no more than its minimum; fillHeight hands it the rest.
              Layout.minimumHeight: Style.space(120)
              Layout.preferredHeight: Style.space(120)
              clip: true
              spacing: Style.space(6)
              boundsBehavior: Flickable.StopAtBounds
              model: root.people
              ScrollBar.vertical: ScrollBar {
                policy: peopleList.contentHeight > peopleList.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
              }
              delegate: PersonRow {
                required property var modelData
                required property int index
                width: ListView.view.width
                person: modelData
                rowIndex: index
              }
            }
          }

          // ------------------------------------------------------- footer
          Item {
            visible: TupleStore.probed
            Layout.fillWidth: true
            Layout.minimumHeight: implicitHeight
            implicitHeight: Math.max(footerText.implicitHeight, footerActions.implicitHeight)

            Text {
              id: footerText
              anchors.left: parent.left
              anchors.right: footerActions.left
              anchors.verticalCenter: parent.verticalCenter
              text: !TupleStore.installed ? "" : "Tuple " + (TupleStore.version || "")
                + (TupleStore.updateVersion !== "" ? " · " + TupleStore.updateVersion + " available" : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Row {
              id: footerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              PanelActionButton {
                visible: TupleStore.updateVersion !== ""
                iconText: "\u{f01da}"
                tooltipText: "Update Tuple"
                foreground: root.accent
                fontFamily: root.fontFamily
                onClicked: TupleStore.install()
              }

              PanelActionButton {
                iconText: "\u{f00e4}"
                tooltipText: "Something wrong? Diagnose with my agent"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: TupleStore.diagnose()
              }

              PanelActionButton {
                visible: TupleStore.loggedIn
                iconText: "\u{f0343}"
                tooltipText: "Sign out"
                foreground: root.foreground
                hoverColor: root.urgent
                fontFamily: root.fontFamily
                onClicked: TupleStore.signOut()
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  // Up to four and a half rows, so a cut-off row shows there is more to
  // scroll; the layout may squeeze it to one and a half to keep the footer.
  component RoomList: ListView {
    id: list
    readonly property real pitch: count > 0 ? (contentHeight + spacing) / count : 0
    visible: count > 0
    Layout.fillWidth: true
    Layout.fillHeight: true
    Layout.preferredHeight: Layout.maximumHeight
    Layout.maximumHeight: Math.min(contentHeight, pitch * 4.5 - spacing)
    Layout.minimumHeight: Math.min(contentHeight, pitch * 1.5 - spacing)
    clip: true
    spacing: Style.space(6)
    boundsBehavior: Flickable.StopAtBounds
    // Always shown while there is more, so a list cut on a row boundary still
    // reads as scrollable.
    ScrollBar.vertical: ScrollBar { policy: list.contentHeight > list.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }
    delegate: RoomRow {
      required property var modelData
      required property int index
      width: ListView.view.width
      room: modelData
      rowIndex: index
    }
  }

  component RoomRow: CursorSurface {
    id: roomRow
    property var room: null
    property int rowIndex: 0

    hasCursor: root.cursorActive && root.focusSection === "rooms" && root.roomIndex === rowIndex
    current: room && room.active
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: roomInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor("rooms", roomRow.rowIndex)
      onClicked: TupleStore.joinRoom(roomRow.room)
    }

    RowLayout {
      id: roomInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: roomRow.room && roomRow.room.personal ? "\u{f0004}" : "\u{f0567}"
        color: roomRow.room && roomRow.room.active ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: roomRow.room ? roomRow.room.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: roomRow.room && roomRow.room.active
          textFormat: Text.PlainText
          elide: Text.ElideRight
        }

        // Always present so every row has the two-line height the list cap
        // measures with; empty when nobody is in the room.
        Text {
          Layout.fillWidth: true
          text: roomRow.room ? Model.occupantsLabel(roomRow.room, TupleStore.user ? TupleStore.user.email : "") : ""
          opacity: text !== "" ? 1 : 0
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: roomRow.room && roomRow.room.favorite ? "\u{f04ce}" : "\u{f04d2}"
        tooltipText: roomRow.room && roomRow.room.favorite ? "Unfavorite" : "Favorite"
        foreground: roomRow.room && roomRow.room.favorite ? root.accent : root.foreground
        fontFamily: root.fontFamily
        onClicked: TupleStore.favoriteRoom(roomRow.room)
      }

      PanelActionButton {
        iconText: "\u{f018f}"
        tooltipText: "Copy link"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: TupleStore.copy(roomRow.room ? roomRow.room.url : "")
      }
    }
  }

  component PersonRow: CursorSurface {
    id: personRow
    property var person: null
    property int rowIndex: 0
    readonly property bool reachable: person && (person.status === "online" || person.status === "available")

    hasCursor: root.cursorActive && root.focusSection === "people" && root.personIndex === rowIndex
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: personInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor("people", personRow.rowIndex)
      onClicked: TupleStore.callPerson(personRow.person)
    }

    RowLayout {
      id: personInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      BorderSurface {
        implicitWidth: Style.space(26)
        implicitHeight: Style.space(26)
        radius: Style.cornerRadius > 0 ? Style.cornerRadius : width / 2
        color: "transparent"
        borderSpec: Border.controlSpec("normal", personRow.reachable ? root.accent : root.dim, root.accent)

        Text {
          anchors.centerIn: parent
          text: personRow.person ? personRow.person.initials : "?"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          textFormat: Text.PlainText
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: personRow.person ? personRow.person.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          textFormat: Text.PlainText
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: !personRow.person ? "" : personRow.person.joinable ? "In a call · click to join"
            : (personRow.person.status === "unknown" ? "Offline" : personRow.person.status)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: personRow.person && personRow.person.favorite ? "\u{f04ce}" : "\u{f04d2}"
        tooltipText: personRow.person && personRow.person.favorite ? "Unfavorite" : "Favorite"
        foreground: personRow.person && personRow.person.favorite ? root.accent : root.foreground
        fontFamily: root.fontFamily
        onClicked: TupleStore.favoritePerson(personRow.person)
      }
    }
  }
}
