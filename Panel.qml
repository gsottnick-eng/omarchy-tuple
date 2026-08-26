import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Tuple in the Omarchy bar: install the client, sign in, call a teammate,
// hop into a room, and reach every client setting from one dropdown.
Panel {
  id: root
  moduleName: "io.github.gsottnick-eng.tuple"
  ipcTarget: "io.github.gsottnick-eng.tuple"
  manageIpc: false

  // ------------------------------------------------------------ appearance
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color online: Color.accent
  readonly property color barIconColor: tuple.installed && tuple.loggedIn
    ? barForeground
    : Qt.darker(barForeground, 1.55)

  // ---------------------------------------------------------------- cursor
  property string focusSection: "header"
  property int roomIndex: 0
  property int personIndex: 0
  property int settingIndex: 0
  property bool cursorActive: false

  // ------------------------------------------------------------------ view
  property bool settingsOpen: false
  property bool addRoomOpen: false

  // PanelKeyCatcher claims plain letters for navigation, so it has to stand
  // down while any inline editor has focus or a room link cannot be typed.
  property int editorsFocused: 0

  readonly property var rooms: tuple.rooms
  readonly property var people: tuple.contacts
  readonly property var clientSettings: tuple.clientSettings

  readonly property bool showSetup: !tuple.installed
  readonly property bool showSignIn: tuple.installed && !tuple.loggedIn
  readonly property bool showCall: tuple.installed && tuple.inCall
  readonly property bool showRooms: tuple.installed && tuple.loggedIn
  readonly property bool showPeople: tuple.installed && tuple.loggedIn
  readonly property bool showSettings: tuple.installed && settingsOpen && clientSettings.length > 0
  readonly property bool showAudio: tuple.installed && tuple.audioAvailable

  readonly property string heroTitle: {
    if (!tuple.installed) return "Tuple"
    if (tuple.inCall) return "On a call"
    if (!tuple.loggedIn) return "Tuple"
    return "Tuple"
  }

  readonly property string barLabel: {
    if (!tuple.installed) return "Tuple"
    if (tuple.inCall) return tuple.sharing ? "Sharing" : "In call"
    if (!tuple.loggedIn) return "Sign in"
    return "Tuple"
  }

  // -------------------------------------------------------------- helpers

  function sectionOrder() {
    var order = ["header"]
    if (showCall) order.push("call")
    // Settings sits directly under the header: it is the first thing wanted
    // after installing, and burying it under contacts made it hard to find.
    if (showSettings) order.push("settings")
    if (showRooms) order.push("rooms")
    if (showPeople && people.length > 0) order.push("people")
    return order
  }

  function sectionLength(section) {
    if (section === "rooms") return rooms.length
    if (section === "people") return people.length
    if (section === "settings") return clientSettings.length
    return 1
  }

  function sectionIndex(section) {
    if (section === "rooms") return roomIndex
    if (section === "people") return personIndex
    if (section === "settings") return settingIndex
    return 0
  }

  function setSectionIndex(section, value) {
    if (section === "rooms") roomIndex = value
    else if (section === "people") personIndex = value
    else if (section === "settings") settingIndex = value
  }

  function ensureCursor() {
    var order = sectionOrder()
    if (order.indexOf(focusSection) === -1) focusSection = order[0]
    var max = Math.max(0, sectionLength(focusSection) - 1)
    if (sectionIndex(focusSection) > max) setSectionIndex(focusSection, max)
    if (sectionIndex(focusSection) < 0) setSectionIndex(focusSection, 0)
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    var order = sectionOrder()
    var at = order.indexOf(focusSection)
    var index = sectionIndex(focusSection)
    var last = sectionLength(focusSection) - 1

    if (dy > 0) {
      if (index < last) setSectionIndex(focusSection, index + 1)
      else if (at < order.length - 1) {
        focusSection = order[at + 1]
        setSectionIndex(focusSection, 0)
      }
    } else {
      if (index > 0) setSectionIndex(focusSection, index - 1)
      else if (at > 0) {
        focusSection = order[at - 1]
        setSectionIndex(focusSection, Math.max(0, sectionLength(focusSection) - 1))
      }
    }
    ensureCursor()
    scrollCursorIntoView()
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") {
      if (!tuple.installed) tuple.install()
      else if (!tuple.loggedIn) tuple.beginLogin()
      else tuple.newCall()
    } else if (focusSection === "call") {
      tuple.endCall()
    } else if (focusSection === "rooms") {
      joinRoom(rooms[roomIndex])
    } else if (focusSection === "people") {
      tuple.callContact(people[personIndex])
    } else if (focusSection === "settings") {
      tuple.toggleSetting(clientSettings[settingIndex])
    }
  }

  function setCursor(section, index) {
    cursorActive = true
    focusSection = section
    setSectionIndex(section, index)
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    var column = focusSection === "rooms" ? roomColumn
      : (focusSection === "people" ? peopleColumn
      : (focusSection === "settings" ? settingColumn : null))
    if (!column) return
    var index = sectionIndex(focusSection)
    if (index >= 0 && index < column.children.length) scrollItemIntoView(column.children[index])
  }

  function joinRoom(room) {
    if (!room) return
    tuple.joinUrl(room.url, "Joining " + room.name + "…")
  }

  // Saved rooms and the personal room URL live in this widget's own shell.json
  // entry, so they survive a shell restart without the plugin owning a config
  // file of its own.
  function persist(key, value) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") {
      tuple.reportError("Could not save: this Omarchy build has no inline widget settings.")
      return
    }
    var entry = { id: root.moduleName }
    for (var name in settings) if (name !== "id") entry[name] = settings[name]
    entry[key] = value
    bar.shell.updateEntryInline(root.moduleName, entry)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    tuple.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onRoomsChanged: ensureCursor()
  onPeopleChanged: ensureCursor()
  onClientSettingsChanged: ensureCursor()

  Service {
    id: tuple
    settings: root.settings
    onSaveRoomsRequested: function(next) { root.persist("savedRooms", next) }
    onPersonalUrlDiscovered: function(url) { root.persist("personalUrl", url) }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { tuple.refresh(); return "ok" }
    function status(): string { return tuple.statusSummary }
    function mute(): string { tuple.toggleMute(); return "ok" }
    function share(): string { tuple.toggleShare(); return "ok" }
    function hangUp(): string { tuple.endCall(); return "ok" }
    function join(url: string): string { return tuple.joinUrl(url) ? "ok" : "invalid url" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.setting("showLabel", false) === true ? root.barLabel : ""
    tooltipText: "Tuple — " + tuple.statusSummary
    iconComponent: Component {
      Item {
        TupleIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          badgeColor: root.urgent
          filled: tuple.inCall
          crossed: tuple.installed && !tuple.daemonRunning
          warning: !tuple.installed || (tuple.installed && !tuple.loggedIn)
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) tuple.refresh()
      else if (buttonCode === Qt.RightButton && tuple.inCall) tuple.toggleMute()
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editorsFocused > 0
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "m" && tuple.inCall) tuple.toggleMute()
        else if (key === "s" && tuple.inCall) tuple.toggleShare()
        else if (key === "e" && tuple.inCall) tuple.endCall()
        else if (key === "n" && tuple.loggedIn) tuple.newCall()
        else if (key === "o") tuple.cycleAudioOutput()
        else if (key === "i") tuple.cycleAudioInput()
        else if (key === "r") tuple.refresh()
        else if (key === ",") root.settingsOpen = !root.settingsOpen
        else if (key === "a" && root.showRooms) root.addRoomOpen = !root.addRoomOpen
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ------------------------------------------------------- header
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.cursorActive && root.focusSection === "header"
            function focusHero() { root.setCursor("header", 0) }

            PanelHero {
              id: hero
              width: parent.width
              title: root.heroTitle
              meta: tuple.statusSummary
              detail: tuple.inCall && tuple.sharing ? "SHARING" : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: tuple.installed && tuple.loggedIn ? 1.0 : 0.55
              iconComponent: Component {
                TupleIcon {
                  iconSize: Style.font.display
                  color: tuple.inCall ? root.online : root.foreground
                  badgeColor: root.urgent
                  filled: tuple.inCall
                  crossed: tuple.installed && !tuple.daemonRunning
                  warning: !tuple.installed
                }
              }

              // The daemon switch is the header's only cursor target: it is
              // the one control that makes sense before sign in.
              trailingControl: Component {
                ToggleSwitch {
                  id: daemonSwitch
                  visible: tuple.installed
                  checked: tuple.daemonRunning
                  busy: tuple.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: tuple.daemonRunning ? tuple.stopDaemon() : tuple.startDaemon()

                  PanelToolTip {
                    visible: daemonSwitch.containsMouse
                    text: tuple.daemonRunning ? "Stop the Tuple daemon" : "Start the Tuple daemon"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // ------------------------------------------------------ feedback
          Text {
            visible: tuple.actionStatus !== "" || tuple.lastError !== ""
            width: parent.width
            text: tuple.actionStatus !== "" ? tuple.actionStatus : tuple.lastError
            color: tuple.lastError !== "" && tuple.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // --------------------------------------------------------- setup
          Column {
            visible: root.showSetup
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: tuple.probed
                ? "Tuple for Linux is not installed yet. This downloads the official client, checks it against Tuple's published checksum, and puts it in " + tuple.installDir + "."
                : "Looking for the Tuple client…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: tuple.installing || tuple.installStage !== ""
              width: parent.width
              text: tuple.installMessage
              color: tuple.installStage === "error" ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Button {
              visible: tuple.probed
              text: tuple.installing ? "Installing…" : (tuple.installStage === "error" ? "Try again" : "Install Tuple")
              enabled: !tuple.installing
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.focusSection === "header"
              onClicked: tuple.install()
            }
          }

          // ------------------------------------------------------- sign in
          Column {
            visible: root.showSignIn
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: tuple.awaitingAuthCode
                ? "Finish signing in in your browser, then paste the authorization code here."
                : "Sign in to Tuple to see your contacts and rooms."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              visible: !tuple.awaitingAuthCode
              spacing: Style.space(8)

              Button {
                text: tuple.loggingIn ? "Starting…" : "Sign in"
                enabled: !tuple.loggingIn
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "header"
                onClicked: tuple.beginLogin()
              }
            }

            Row {
              visible: tuple.awaitingAuthCode
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: authField
                onActiveFocusChanged: root.editorsFocused += activeFocus ? 1 : -1
                width: parent.width - finishButton.width - openButton.width - Style.space(12)
                foreground: root.foreground
                placeholderText: "Authorization code"
                onAccepted: if (tuple.submitAuthCode(text)) text = ""
              }

              Button {
                id: finishButton
                text: "Finish"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (tuple.submitAuthCode(authField.text)) authField.text = ""
              }

              PanelActionButton {
                id: openButton
                iconText: "󰖟"
                tooltipText: "Reopen the sign-in page"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: tuple.openLoginUrl()
              }
            }
          }

          // ---------------------------------------------------- call panel
          PanelSeparator { visible: root.showCall; foreground: root.foreground }

          Column {
            visible: root.showCall
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "CURRENT CALL"
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
                    text: tuple.muted ? "Microphone muted" : "Microphone live"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    Layout.fillWidth: true
                    text: tuple.sharing ? "Sharing your screen" : "Not sharing"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  iconText: tuple.muted ? "󰍭" : "󰍬"
                  tooltipText: tuple.muted ? "Unmute (m)" : "Mute (m)"
                  foreground: tuple.muted ? root.urgent : root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: tuple.toggleMute()
                }

                PanelActionButton {
                  iconText: tuple.sharing ? "󰹙" : "󰍹"
                  tooltipText: tuple.sharing ? "Stop sharing (s)" : "Share screen (s)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: tuple.toggleShare()
                }

                PanelActionButton {
                  iconText: "󰜺"
                  tooltipText: "Leave the call (e)"
                  foreground: root.foreground
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: tuple.endCall()
                }
              }
            }
          }

          // ------------------------------------------------------ settings
          PanelSeparator { visible: tuple.installed; foreground: root.foreground }

          Column {
            visible: tuple.installed
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(settingsHeading.implicitHeight, settingsToggle.implicitHeight)

              PanelSectionHeader {
                id: settingsHeading
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "SETTINGS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              PanelActionButton {
                id: settingsToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.settingsOpen ? "󰅁" : "󰅂"
                tooltipText: root.settingsOpen ? "Hide settings (,)" : "Show settings (,)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.settingsOpen = !root.settingsOpen
              }
            }

            Column {
              id: settingColumn
              visible: root.showSettings
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.clientSettings
                SettingRow {
                  required property var modelData
                  required property int index
                  width: settingColumn.width
                  entry: modelData
                  rowIndex: index
                }
              }
            }
          }

          // --------------------------------------------------------- audio
          // Tuple's client cannot choose a microphone or speaker, so this is
          // PipeWire's default device rather than a per-call route. Hidden
          // entirely when pactl is not present.
          PanelSeparator { visible: root.showAudio; foreground: root.foreground }

          Column {
            visible: root.showAudio
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "AUDIO"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            AudioRow {
              width: parent.width
              caption: "Output"
              deviceLabel: Model.activeDeviceLabel(tuple.audioOutputs, tuple.audioOutput)
              count: tuple.audioOutputs.length
              shortcutHint: "o"
              onActivated: tuple.cycleAudioOutput()
            }

            AudioRow {
              width: parent.width
              caption: "Microphone"
              deviceLabel: Model.activeDeviceLabel(tuple.audioInputs, tuple.audioInput)
              count: tuple.audioInputs.length
              shortcutHint: "i"
              onActivated: tuple.cycleAudioInput()
            }
          }

          // --------------------------------------------------------- rooms
          PanelSeparator { visible: root.showRooms; foreground: root.foreground }

          Column {
            visible: root.showRooms
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(roomsHeading.implicitHeight, addRoomButton.implicitHeight)

              PanelSectionHeader {
                id: roomsHeading
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "ROOMS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              PanelActionButton {
                id: addRoomButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.addRoomOpen ? "󰅖" : "󰐕"
                tooltipText: root.addRoomOpen ? "Cancel" : "Save a room (a)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.addRoomOpen = !root.addRoomOpen
                  if (root.addRoomOpen) Qt.callLater(function() { roomInput.forceActiveFocus() })
                }
              }
            }

            Column {
              visible: root.addRoomOpen
              width: parent.width
              spacing: Style.space(6)

              Text {
                width: parent.width
                text: tuple.supportsRooms
                  ? "Paste a Tuple room or call link."
                  : "This client can't list rooms yet, so save the ones you use. In Tuple, copy a room's call link (tuple.app/c/…) and paste it here."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Row {
                width: parent.width
                spacing: Style.space(6)

                TextField {
                  id: roomInput
                  onActiveFocusChanged: root.editorsFocused += activeFocus ? 1 : -1
                  width: parent.width - roomNameInput.width - saveRoomButton.width - Style.space(12)
                  foreground: root.foreground
                  placeholderText: "https://tuple.app/c/…"
                  onAccepted: root.commitRoom()
                }

                TextField {
                  id: roomNameInput
                  onActiveFocusChanged: root.editorsFocused += activeFocus ? 1 : -1
                  width: Style.space(110)
                  foreground: root.foreground
                  placeholderText: "Name"
                  onAccepted: root.commitRoom()
                }

                PanelActionButton {
                  id: saveRoomButton
                  iconText: "󰆓"
                  tooltipText: "Save room"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.commitRoom()
                }
              }
            }

            Text {
              visible: root.rooms.length === 0 && !root.addRoomOpen
              width: parent.width
              text: "No rooms yet. Use + to save the rooms you join most."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: roomColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.rooms
                RoomRow {
                  required property var modelData
                  required property int index
                  width: roomColumn.width
                  room: modelData
                  rowIndex: index
                }
              }
            }
          }

          // -------------------------------------------------------- people
          PanelSeparator { visible: root.showPeople; foreground: root.foreground }

          Column {
            visible: root.showPeople
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "PEOPLE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.people.length === 0
              width: parent.width
              text: tuple.refreshing ? "Loading contacts…" : "No contacts yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: peopleColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.people
                PersonRow {
                  required property var modelData
                  required property int index
                  width: peopleColumn.width
                  person: modelData
                  rowIndex: index
                }
              }
            }
          }

          // -------------------------------------------------------- footer
          Item {
            width: parent.width
            implicitHeight: footerText.implicitHeight + Style.space(4)

            Text {
              id: footerText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: tuple.installed
                ? "Tuple " + (tuple.clientVersion !== "" ? tuple.clientVersion : "client") + (tuple.supportsRooms ? "" : " · alpha")
                : "Not installed"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑐"
              tooltipText: "Refresh (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: tuple.refresh()
            }
          }
        }
      }
    }
  }

  function commitRoom() {
    if (tuple.saveRoom(roomInput.text, roomNameInput.text)) {
      roomInput.text = ""
      roomNameInput.text = ""
      addRoomOpen = false
    }
  }

  // ------------------------------------------------------------ components

  component RoomRow: CursorSurface {
    id: roomRow
    property var room: null
    property int rowIndex: 0
    readonly property bool joining: room && tuple.joiningUrl === room.url
    readonly property string occupancy: room ? Model.occupancyLabel(room) : ""
    readonly property bool occupied: room && room.occupants > 0

    hasCursor: root.cursorActive && root.focusSection === "rooms" && root.roomIndex === rowIndex
    current: occupied || joining
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: roomInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor("rooms", roomRow.rowIndex)
      onClicked: root.joinRoom(roomRow.room)
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
        text: roomRow.room && roomRow.room.kind === "personal" ? "󰀄" : "󰕧"
        color: roomRow.occupied ? root.online : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
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
          font.bold: roomRow.occupied
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: {
            if (roomRow.joining) return "Joining…"
            var parts = []
            if (roomRow.occupancy !== "") parts.push(roomRow.occupancy)
            if (roomRow.room && roomRow.room.slug !== "") parts.push(roomRow.room.slug)
            return parts.join(" · ")
          }
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: roomRow.room && roomRow.room.favorite ? "󰓎" : "󰓒"
        tooltipText: roomRow.room && roomRow.room.favorite ? "Unpin" : "Pin"
        foreground: roomRow.room && roomRow.room.favorite ? root.online : root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: tuple.toggleRoomFavorite(roomRow.room)
      }

      PanelActionButton {
        iconText: "󰆏"
        tooltipText: "Copy link"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: tuple.copyToClipboard(roomRow.room ? roomRow.room.url : "")
      }

      PanelActionButton {
        visible: roomRow.room && roomRow.room.kind === "saved"
        iconText: "󰩹"
        tooltipText: "Forget this room"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: tuple.forgetRoom(roomRow.room)
      }
    }
  }

  component PersonRow: CursorSurface {
    id: personRow
    property var person: null
    property int rowIndex: 0
    readonly property bool online: person && (person.status === "online" || person.status === "available")

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
      onClicked: tuple.callContact(personRow.person)
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
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
        Layout.alignment: Qt.AlignVCenter

        Text {
          anchors.centerIn: parent
          text: personRow.person ? personRow.person.initials : "?"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
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
          font.bold: personRow.person && personRow.person.favorite
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: personRow.person ? personRow.person.email : ""
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: personRow.person && personRow.person.favorite ? "󰓎" : "󰓒"
        tooltipText: personRow.person && personRow.person.favorite ? "Unfavorite" : "Favorite"
        foreground: personRow.person && personRow.person.favorite ? root.online : root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: tuple.favorite(personRow.person, !(personRow.person && personRow.person.favorite))
      }

      PanelActionButton {
        iconText: "󰏲"
        tooltipText: "Call"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: tuple.callContact(personRow.person)
      }
    }
  }

  component AudioRow: CursorSurface {
    id: audioRow
    property string caption: ""
    property string deviceLabel: ""
    property int count: 0
    property string shortcutHint: ""
    signal activated()

    hasCursor: false
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: audioInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: audioRow.count > 1 ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (audioRow.count > 1) audioRow.activated()
    }

    RowLayout {
      id: audioInner
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
          text: audioRow.caption
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: audioRow.deviceLabel !== "" ? audioRow.deviceLabel : "No device"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: audioRow.count > 1
        text: audioRow.shortcutHint
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component SettingRow: CursorSurface {
    id: settingRow
    property var entry: null
    property int rowIndex: 0
    readonly property bool pending: entry && tuple.pendingSetting === entry.key

    hasCursor: root.cursorActive && root.focusSection === "settings" && root.settingIndex === rowIndex
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: settingInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: root.setCursor("settings", settingRow.rowIndex)
    }

    RowLayout {
      id: settingInner
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
          text: settingRow.entry ? settingRow.entry.key : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: settingRow.entry ? settingRow.entry.label : ""
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      ToggleSwitch {
        visible: settingRow.entry && settingRow.entry.kind === "bool"
        checked: settingRow.entry && settingRow.entry.checked
        busy: settingRow.pending
        foreground: root.foreground
        cursorRing: false
        Layout.alignment: Qt.AlignVCenter
        onToggled: tuple.toggleSetting(settingRow.entry)
      }

      Button {
        visible: settingRow.entry && settingRow.entry.kind === "enum"
        text: settingRow.entry ? settingRow.entry.value : ""
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        tooltipText: "Cycle value"
        Layout.alignment: Qt.AlignVCenter
        onClicked: tuple.toggleSetting(settingRow.entry)
      }

      TextField {
        id: settingField
        onActiveFocusChanged: root.editorsFocused += activeFocus ? 1 : -1
        visible: settingRow.entry && settingRow.entry.kind === "string"
        width: Style.space(140)
        foreground: root.foreground
        placeholderText: "not set"
        text: settingRow.entry ? settingRow.entry.value : ""
        Layout.alignment: Qt.AlignVCenter
        onAccepted: tuple.applySetting(settingRow.entry, text)
      }
    }
  }
}
