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
  moduleName: "io.github.gsottnick.omatuple"
  ipcTarget: "io.github.gsottnick.omatuple"
  // The handler below adds call verbs to open/close. Built once per monitor,
  // only the first registers; the rest log a warning, as first-party widgets do.
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  // Appearance settings, all read from this widget's shell.json entry.
  readonly property string barStyle: Model.barStyle(settings)
  readonly property var metrics: Model.panelMetrics(setting("panelSize", "normal"))
  readonly property bool showRooms: Model.toBool(setting("showRooms", true), true)
  readonly property bool showPeople: Model.toBool(setting("showPeople", true), true)
  readonly property bool listsShown: ready && !paged && (showRooms || showPeople)
  // A theme role rather than a colour, so it follows theme changes.
  readonly property string accentRole: setting("accent", "theme")
  readonly property color accent: accentRole === "foreground" ? Color.foreground
    : (accentRole === "urgent" ? Color.urgent : Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, accent)

  readonly property bool ready: TupleStore.installed && TupleStore.loggedIn
  // Unverified against a real incoming call: a call this side did not start
  // that has not connected yet is treated as ringing.
  readonly property bool ringing: TupleStore.inCall && !TupleStore.connected && TupleStore.calling === ""
  readonly property var rooms: ready && showRooms ? Model.visibleRooms(TupleStore.rooms, search) : []
  readonly property var people: ready && showPeople ? Model.visibleContacts(TupleStore.contacts, search) : []
  property string search: ""

  property string focusSection: "header"
  property int roomIndex: 0
  property int personIndex: 0
  property bool cursorActive: false
  // PanelKeyCatcher claims plain letters, so it stands down while a text
  // field has focus.
  property int editorsFocused: 0

  readonly property string barText: Model.barText(barStyle, {
    loggedIn: TupleStore.loggedIn, inCall: TupleStore.inCall, muted: TupleStore.muted,
    sharing: TupleStore.sharing, participants: TupleStore.participants
  })

  // Alerts and sounds belong to the one store, set from this widget's settings.
  function syncStore(): void {
    TupleStore.callAlerts = Model.toBool(setting("callAlerts", true), true)
    TupleStore.soundParticipants = Model.toBool(setting("soundParticipants", true), true)
    TupleStore.soundCall = Model.toBool(setting("soundCall", true), true)
    TupleStore.soundMute = Model.toBool(setting("soundMute", true), true)
    TupleStore.soundShare = Model.toBool(setting("soundShare", true), true)
  }
  onSettingsChanged: syncStore()
  Component.onCompleted: syncStore()

  // ------------------------------------------------------------- keyboard

  function sectionOrder() {
    var order = ["header"]
    if (TupleStore.inCall) order.push("call")
    if (rooms.length > 0 && !paged) order.push("rooms")
    if (people.length > 0 && !paged) order.push("people")
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
    shareWarningOpen = false
    page = ""
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
  // XWAYLAND-SHARE-WORKAROUND: starting a share crashes Xwayland on Hyprland (UPSTREAM.md), so
  // every share asks first, until the user turns the warning off. Stopping a
  // share never asks. Temporary: delete everything tagged XWAYLAND-SHARE-WORKAROUND (here, the
  // warning row, the help page and its footer button, the manifest setting,
  // their tests) once the upstream fix ships; shareFromPanel() then just calls
  // shareAnyway().
  property bool shareWarningOpen: false
  readonly property bool warnBeforeSharing: Model.toBool(setting("warnBeforeSharing", true), true)

  function shareFromPanel(): void {
    if (!TupleStore.sharing && warnBeforeSharing) {
      shareWarningOpen = true
      return
    }
    shareAnyway()
  }

  function shareAnyway(): void {
    shareWarningOpen = false
    root.close()
    TupleStore.toggleShare()
  }

  function shareAndStopWarning(): void {
    persistSettings({ warnBeforeSharing: false })
    shareAnyway()
  }

  // One page at a time over the room and people lists: "" is the lists,
  // "help" explains why sharing breaks the desktop, "settings" holds the
  // widget's settings. The call stays on top.
  property string page: ""
  readonly property bool paged: page !== ""

  function togglePage(name): void {
    page = page === name ? "" : name
    if (paged) pageView.contentY = 0
  }

  function scrollPage(dy): void {
    var end = Math.max(0, pageView.contentHeight - pageView.height)
    pageView.contentY = Math.max(0, Math.min(end, pageView.contentY + dy * Style.space(40)))
  }

  // Esc leaves a page before it closes the panel.
  function back(): void {
    if (paged) page = ""
    else close()
  }

  // Omarchy's own pattern (its clock panel): apply locally so the panel
  // updates on the click, then write this widget's shell.json entry.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

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
          color: !root.ready ? Qt.darker(root.barForeground, 1.55) : (TupleStore.inCall ? root.accent : root.barForeground)
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
    objectName: "keyboardPanel"
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.metrics.width))
    // Signed in, the panel keeps one height and its content scrolls, so
    // searching never resizes it. Setup and sign-in fit their few lines.
    contentHeight: panel.fittedContentHeight(root.ready || root.paged ? Style.space(root.metrics.height) : column.implicitHeight, Style.space(root.metrics.height))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editorsFocused > 0
      onMoveRequested: function(dx, dy) {
        if (root.paged) { root.scrollPage(dy); return }
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.back()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "m") TupleStore.toggleMute()
        else if (key === "s") root.shareFromPanel()
        else if (key === "l") TupleStore.leave()
        else if (key === "a" && root.ringing) TupleStore.accept()
        else if (key === "/" && root.listsShown) searchField.forceActiveFocus()
      }

      // The panel itself does not scroll: each list scrolls on its own, and
      // People takes whatever height is left.
      Item {
        anchors.fill: parent
        clip: true

        ColumnLayout {
          id: column
          width: parent.width
          height: root.ready || root.paged ? parent.height : implicitHeight
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
              textFormat: Text.PlainText
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

            // XWAYLAND-SHARE-WORKAROUND: the warning row.
            Column {
              visible: root.shareWarningOpen && TupleStore.inCall && !TupleStore.sharing
              width: parent.width
              spacing: Style.space(6)

              Text {
                width: parent.width
                text: "Sharing will crash your open X11 apps (Steam, Zoom, games) and stop you from viewing others' screens until you log out and back in, which closes your open apps. This is a Tuple and Xwayland bug, not Omatuple."
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Row {
                spacing: Style.space(6)

                Button {
                  text: "Share anyway"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.shareAnyway()
                }

                // Fades in over a second, clickable only once fully shown, so
                // the warning gets read before it can be turned off for good.
                Button {
                  text: "Don't show again"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  opacity: 0
                  enabled: opacity >= 1
                  onClicked: root.shareAndStopWarning()

                  NumberAnimation on opacity {
                    from: 0
                    to: 1
                    duration: 1000
                    running: root.shareWarningOpen
                  }
                }

                Button {
                  text: "Cancel"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.shareWarningOpen = false
                }
              }
            }

          }

          // -------------------------------------------------------- rooms
          PanelSeparator { Layout.fillWidth: true; Layout.minimumHeight: implicitHeight; visible: root.listsShown; foreground: root.foreground }

          // One field: typing filters rooms and people, a pasted link joins on Enter.
          TextField {
            id: searchField
            visible: root.listsShown
            Layout.fillWidth: true
            Layout.minimumHeight: implicitHeight
            onActiveFocusChanged: root.editorsFocused += activeFocus ? 1 : -1
            foreground: root.foreground
            placeholderText: "Search, or paste a link to join (/)"
            onTextChanged: root.search = text
            onAccepted: if (Model.isJoinableUrl(text) && TupleStore.joinUrl(text)) text = ""
          }

          ColumnLayout {
            objectName: "roomsSection"
            visible: root.listsShown && root.showRooms
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
          PanelSeparator { Layout.fillWidth: true; Layout.minimumHeight: implicitHeight; visible: root.listsShown && root.showRooms && root.showPeople; foreground: root.foreground }

          ColumnLayout {
            objectName: "peopleSection"
            visible: root.listsShown && root.showPeople
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

          // --------------------------------------------------------- page
          PanelSeparator { Layout.fillWidth: true; Layout.minimumHeight: implicitHeight; visible: root.paged; foreground: root.foreground }

          ColumnLayout {
            visible: root.paged
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(8)

            RowLayout {
              Layout.fillWidth: true
              Layout.minimumHeight: implicitHeight
              spacing: Style.space(6)

              PanelActionButton {
                iconText: "\u{f004d}"
                tooltipText: "Back (Esc)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.back()
              }

              PanelSectionHeader {
                Layout.fillWidth: true
                // XWAYLAND-SHARE-WORKAROUND: the help page's title.
                text: root.page === "help" ? "WHY SHARING BREAKS X11 APPS" : "SETTINGS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
            }

            // Pages scroll on their own; the call and footer stay put.
            Flickable {
              id: pageView
              objectName: "pageView"
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              contentWidth: width
              contentHeight: pageContent.implicitHeight
              ScrollBar.vertical: ScrollBar {
                policy: pageView.contentHeight > pageView.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
              }

              Column {
                id: pageContent
                width: pageView.width - Style.space(14)

                // XWAYLAND-SHARE-WORKAROUND: the help page.
                Column {
                  visible: root.page === "help"
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    width: parent.width
                    text: "Starting a screen share makes Xwayland crash. Xwayland is the part of your desktop that runs older X11 apps like Steam, Zoom and many games, and Tuple's own window for viewing other people's screens. "
                      + "This isn't Omatuple: it happens inside Tuple's Linux client and Xwayland, and Hyprland doesn't restart Xwayland afterwards. "
                      + "Tuple, X.org and Hyprland have to fix it.\n\n"
                      + "After you share, X11 apps won't open and you can't view anyone's screen until you log out and back in, and logging out closes your open apps. "
                      + "Until it's fixed: close X11 apps before sharing, and plan to log out and back in afterwards."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  Button {
                    text: "Details"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: Qt.openUrlExternally("file://" + TupleStore.pluginDir + "/UPSTREAM.md")
                  }
                }

                // Each choice is saved to this widget's shell.json entry at once.
                Column {
                  objectName: "settingsPage"
                  visible: root.page === "settings"
                  width: parent.width
                  spacing: Style.space(10)

                  PanelSectionHeader { text: "BAR"; foreground: root.foreground; fontFamily: root.fontFamily }

                  ChoiceRow {
                    objectName: "barStyleChoice"
                    label: "Next to the icon"
                    options: [{ value: "icon", label: "Nothing" }, { value: "status", label: "Status" }, { value: "who", label: "Who" }]
                    value: root.barStyle
                    onPicked: function(value) { root.persistSettings({ barStyle: value }) }
                  }

                  PanelSectionHeader { text: "PANEL"; foreground: root.foreground; fontFamily: root.fontFamily }

                  ChoiceRow {
                    objectName: "panelSizeChoice"
                    label: "Size"
                    options: [{ value: "compact", label: "Compact" }, { value: "normal", label: "Normal" }, { value: "tall", label: "Tall" }]
                    value: root.setting("panelSize", "normal")
                    onPicked: function(value) { root.persistSettings({ panelSize: value }) }
                  }

                  ChoiceRow {
                    objectName: "accentChoice"
                    label: "Highlight colour"
                    options: [{ value: "theme", label: "Theme" }, { value: "foreground", label: "Text" }, { value: "urgent", label: "Alert" }]
                    value: root.accentRole
                    onPicked: function(value) { root.persistSettings({ accent: value }) }
                  }

                  SettingToggle {
                    objectName: "showRoomsToggle"
                    label: "Show rooms"
                    checked: root.showRooms
                    onClicked: root.persistSettings({ showRooms: !root.showRooms })
                  }

                  SettingToggle {
                    objectName: "showPeopleToggle"
                    label: "Show people"
                    checked: root.showPeople
                    onClicked: root.persistSettings({ showPeople: !root.showPeople })
                  }

                  PanelSectionHeader { text: "ALERTS"; foreground: root.foreground; fontFamily: root.fontFamily }

                  SettingToggle {
                    objectName: "callAlertsToggle"
                    label: "Call notifications"
                    description: "When a call starts or ends, and when someone joins or leaves"
                    checked: TupleStore.callAlerts
                    onClicked: root.persistSettings({ callAlerts: !TupleStore.callAlerts })
                  }

                  PanelSectionHeader { text: "SOUNDS"; foreground: root.foreground; fontFamily: root.fontFamily }

                  SettingToggle {
                    objectName: "soundParticipantsToggle"
                    label: "Someone joins or leaves"
                    checked: TupleStore.soundParticipants
                    onClicked: root.persistSettings({ soundParticipants: !TupleStore.soundParticipants })
                  }

                  SettingToggle {
                    objectName: "soundCallToggle"
                    label: "Your call starts or ends"
                    checked: TupleStore.soundCall
                    onClicked: root.persistSettings({ soundCall: !TupleStore.soundCall })
                  }

                  SettingToggle {
                    objectName: "soundMuteToggle"
                    label: "Mute and unmute"
                    checked: TupleStore.soundMute
                    onClicked: root.persistSettings({ soundMute: !TupleStore.soundMute })
                  }

                  SettingToggle {
                    objectName: "soundShareToggle"
                    label: "Screen share starts or stops"
                    checked: TupleStore.soundShare
                    onClicked: root.persistSettings({ soundShare: !TupleStore.soundShare })
                  }

                  Button {
                    objectName: "soundTest"
                    text: "Play a test sound"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: TupleStore.play("joined")
                  }

                  PanelSectionHeader { text: "WARNINGS"; foreground: root.foreground; fontFamily: root.fontFamily }

                  // XWAYLAND-SHARE-WORKAROUND: the warning's setting.
                  SettingToggle {
                    objectName: "warnBeforeSharingToggle"
                    label: "Warn before sharing"
                    description: "Sharing your screen crashes X11 apps"
                    checked: root.warnBeforeSharing
                    onClicked: root.persistSettings({ warnBeforeSharing: !root.warnBeforeSharing })
                  }
                }
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

              // XWAYLAND-SHARE-WORKAROUND: the help button.
              PanelActionButton {
                iconText: "\u{f02d7}"
                tooltipText: "Why does sharing break my desktop?"
                foreground: root.page === "help" ? root.accent : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.togglePage("help")
              }

              PanelActionButton {
                iconText: "\u{f0493}"
                tooltipText: "Settings"
                foreground: root.page === "settings" ? root.accent : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.togglePage("settings")
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
  component ChoiceRow: Column {
    id: choice
    property string label: ""
    property alias options: group.options
    property alias value: group.value
    signal picked(string value)
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Text {
      text: choice.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    ButtonGroup {
      id: group
      objectName: choice.objectName + "Group"
      focusable: false
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(value) { choice.picked(value) }
    }
  }

  component SettingToggle: Toggle {
    width: parent ? parent.width : 0
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    titleSize: Style.font.body
  }

  component RoomList: ListView {
    id: list
    readonly property real pitch: count > 0 ? (contentHeight + spacing) / count : 0
    visible: count > 0
    Layout.fillWidth: true
    Layout.fillHeight: true
    Layout.preferredHeight: Layout.maximumHeight
    // With People hidden, rooms take the whole height.
    Layout.maximumHeight: root.showPeople ? Math.min(contentHeight, pitch * 4.5 - spacing) : contentHeight
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
        text: roomRow.room && roomRow.room.personal ? "\u{f0004}" : "\u{f081c}"
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
          textFormat: Text.PlainText
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
