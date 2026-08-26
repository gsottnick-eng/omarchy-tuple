import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Owns everything that talks to the Tuple client: locating the binary,
// probing what the installed client can do, polling contacts and settings,
// and running the one-shot verbs the panel triggers.
//
// The Linux client is command driven and has no read-only status verb, so
// call state comes from the daemon's own log file. An explicit user action
// always takes precedence over what the log last said.
Item {
  id: root

  property var settings: ({})

  // ---------------------------------------------------------- discovery
  property bool probed: false
  property bool installed: false
  property string binaryPath: ""
  property string clientVersion: ""
  property string generation: "legacy"
  readonly property bool supportsRooms: generation === "modern"

  // ---------------------------------------------------------- session
  property bool daemonRunning: false
  property bool loggedIn: false
  property bool loggingIn: false
  property string loginUrl: ""
  property bool awaitingAuthCode: false

  // ---------------------------------------------------------- call
  property bool inCall: false
  property bool sharing: false
  property bool muted: false

  // ---------------------------------------------------------- data
  property var contacts: []
  property var liveRooms: []
  property var clientSettings: []

  // `tuple new` is the only command that reveals the personal room URL, and it
  // joins a call as a side effect — so it is never run to look something up.
  // The URL is captured when the user starts a call and remembered after that.
  property string discoveredPersonalUrl: ""
  readonly property string personalUrl: discoveredPersonalUrl !== ""
    ? discoveredPersonalUrl
    : String(setting("personalUrl", ""))

  // ---------------------------------------------------------- feedback
  property string actionStatus: ""
  property string lastError: ""
  property bool refreshing: false
  property bool installing: false
  property string installStage: ""
  property string installMessage: ""
  property string pendingSetting: ""
  property string joiningUrl: ""

  // Named for the request, not the property: `savedRooms` already generates
  // its own change signal.
  signal saveRoomsRequested(var rooms)
  signal personalUrlDiscovered(string url)

  readonly property bool busy: probeProcess.running || bannerProcess.running
    || contactsProcess.running || settingsProcess.running || actionProcess.running
    || loginProcess.running || installProcess.running || roomsProcess.running
    || pickerProcess.running

  readonly property int refreshIntervalSec: Model.clampInt(setting("refreshIntervalSec", 20), 20, 5, 600)
  readonly property string installDir: String(setting("installDir", "~/.local/bin"))
  readonly property string logPath: {
    var dataHome = Quickshell.env("XDG_DATA_HOME")
    var base = dataHome && dataHome.length > 0 ? dataHome : Quickshell.env("HOME") + "/.local/share"
    return base + "/tuple/0/log.txt"
  }
  readonly property string pluginDir: {
    var dir = String(Qt.resolvedUrl("."))
    return dir.indexOf("file://") === 0 ? dir.substring(7).replace(/\/$/, "") : dir.replace(/\/$/, "")
  }
  readonly property var savedRooms: Model.normalizeSavedRooms(setting("savedRooms", []))
  readonly property var rooms: Model.mergeRooms(personalUrl, savedRooms, liveRooms)
  readonly property string statusSummary: Model.statusSummary({
    installed: installed,
    daemonRunning: daemonRunning,
    loggedIn: loggedIn,
    inCall: inCall,
    sharing: sharing
  })

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function command(args) {
    var out = [binaryPath !== "" ? binaryPath : "tuple"]
    for (var i = 0; i < args.length; i++) out.push(args[i])
    return out
  }

  function note(message) {
    actionStatus = Model.elide(message)
    if (actionStatus !== "") statusTimer.restart()
  }

  function reportError(message) {
    lastError = Model.elide(message)
    actionStatus = ""
  }

  function clearFeedback() {
    lastError = ""
    actionStatus = ""
  }

  // ------------------------------------------------------------- discovery

  function refresh() {
    if (probeProcess.running) return
    refreshing = true
    // `command -v` covers a PATH install; the configured directory covers a
    // fresh install that the running shell's PATH has not picked up yet.
    probeProcess.command = ["sh", "-c",
      'command -v tuple 2>/dev/null && exit 0; d="$1"; case "$d" in "~") d="$HOME";; "~/"*) d="$HOME/${d#\\~/}";; esac; [ -x "$d/tuple" ] && printf %s "$d/tuple"',
      "sh", installDir]
    probeProcess.running = true
  }

  function refreshData() {
    if (!installed) return
    if (!contactsProcess.running) {
      contactsProcess.command = command(["ls"])
      contactsProcess.running = true
    }
    if (!settingsProcess.running) {
      settingsProcess.command = command(["settings"])
      settingsProcess.running = true
    }
    if (supportsRooms && !roomsProcess.running) {
      roomsProcess.command = command(["rooms", "list", "--format", "json"])
      roomsProcess.running = true
    }
    if (!logProcess.running) {
      logProcess.command = ["sh", "-c", '[ -r "$1" ] && tail -n 300 "$1" || true', "sh", logPath]
      logProcess.running = true
    }
    if (!daemonProcess.running) {
      daemonProcess.command = ["sh", "-c", "cat /proc/net/unix 2>/dev/null || true"]
      daemonProcess.running = true
    }
  }

  function applyBanner(raw) {
    var caps = Model.detectCapabilities(raw)
    generation = caps.generation
    if (caps.version !== "") clientVersion = caps.version
  }

  // --------------------------------------------------------------- actions

  function runAction(args, label) {
    if (!installed) return
    if (actionProcess.running) {
      note("Still finishing the last command…")
      return
    }
    clearFeedback()
    if (label) actionStatus = label
    actionProcess.command = command(args)
    actionProcess.running = true
  }

  function startDaemon() { runAction(["on"], "Starting Tuple…") }
  function stopDaemon() { runAction(["off"], "Stopping Tuple…") }
  function endCall() { runAction(["end"], "Leaving the call…") }
  function toggleMute() { runAction([muted ? "unmute" : "mute"], muted ? "Unmuting…" : "Muting…") }
  function toggleShare() { runAction([sharing ? "unshare" : "share"], sharing ? "Stopping share…" : "Sharing screen…") }
  function logout() { runAction(["logout"], "Signing out…") }
  function favorite(contact, on) {
    if (!contact) return
    runAction([on ? "favorite" : "unfavorite", String(contact.selector)],
      (on ? "Favoriting " : "Unfavoriting ") + contact.name + "…")
  }

  function newCall() {
    if (!installed) return
    clearFeedback()
    actionStatus = "Starting a call…"
    personalProcess.command = command(["new"])
    personalProcess.running = true
  }

  function joinUrl(url, label) {
    var normalized = Model.normalizeRoomInput(url)
    if (!normalized.ok) {
      reportError(normalized.message)
      return false
    }
    joiningUrl = normalized.url
    runAction(["join", normalized.url], label || "Joining…")
    return true
  }

  // `tuple call` is interactive: it prints a numbered picker and reads the
  // choice from stdin. Run it once with no input to get the numbering straight
  // from the client, then run it again with the number for this contact. The
  // ids `tuple ls` prints are not picker numbers, so they cannot be reused.
  property var pendingCall: null

  function callContact(contact) {
    if (!installed || !contact) return
    if (actionProcess.running || pickerProcess.running) {
      note("Still finishing the last command…")
      return
    }
    clearFeedback()
    pendingCall = contact
    actionStatus = "Calling " + contact.name + "…"
    pickerProcess.command = ["sh", "-c", 'printf "" | "$1" call', "sh",
      binaryPath !== "" ? binaryPath : "tuple"]
    pickerProcess.running = true
  }

  function applySetting(entry, value) {
    if (!entry || !installed) return
    pendingSetting = entry.key
    runAction(["set", entry.key, String(value)], "Updating " + entry.key + "…")
  }

  function toggleSetting(entry) {
    if (!entry) return
    applySetting(entry, entry.kind === "bool" ? Model.settingToggleValue(entry) : Model.nextEnumValue(entry))
  }

  // ----------------------------------------------------------------- login

  function beginLogin() {
    if (!installed || loginProcess.running) return
    clearFeedback()
    loggingIn = true
    loginUrl = ""
    awaitingAuthCode = false
    _loginOutput = ""
    actionStatus = "Starting sign in…"
    loginProcess.command = command(["login"])
    loginProcess.running = true
  }

  function submitAuthCode(code) {
    var value = String(code || "").replace(/^\s+|\s+$/g, "")
    if (!Model.isAuthCode(value)) {
      reportError("That does not look like an authorization code.")
      return false
    }
    runAction(["auth", value], "Finishing sign in…")
    return true
  }

  function openLoginUrl() {
    if (loginUrl === "") return
    Quickshell.execDetached(["omarchy-launch-browser", loginUrl])
  }

  function copyToClipboard(value) {
    var body = String(value || "")
    if (body === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(body) + " | wl-copy"])
    note("Copied")
  }

  // --------------------------------------------------------------- install

  function install() {
    if (installing || installProcess.running) return
    clearFeedback()
    installing = true
    installStage = "resolve"
    installMessage = Model.installStageLabel("resolve")
    installProcess.command = [pluginDir + "/bin/tuple-install", "--json", "--dest", installDir]
    installProcess.running = true
  }

  // ----------------------------------------------------------------- rooms

  function saveRoom(input, name) {
    var normalized = Model.normalizeRoomInput(input, name)
    if (!normalized.ok) {
      reportError(normalized.message)
      return false
    }
    var next = Model.serializeSavedRooms(savedRooms)
    for (var i = 0; i < next.length; i++) {
      if (next[i].url === normalized.url) {
        reportError("That room is already saved.")
        return false
      }
    }
    next.push({ url: normalized.url, name: normalized.name, favorite: false })
    saveRoomsRequested(next)
    note("Saved " + normalized.name)
    return true
  }

  function forgetRoom(room) {
    if (!room) return
    var next = []
    var current = Model.serializeSavedRooms(savedRooms)
    for (var i = 0; i < current.length; i++) {
      if (current[i].url !== room.url) next.push(current[i])
    }
    saveRoomsRequested(next)
    note("Removed " + room.name)
  }

  function toggleRoomFavorite(room) {
    if (!room) return
    if (room.kind !== "saved") {
      if (supportsRooms) runAction(["rooms", room.favorite ? "unfavorite" : "favorite", room.url], "")
      return
    }
    var next = Model.serializeSavedRooms(savedRooms)
    for (var i = 0; i < next.length; i++) {
      if (next[i].url === room.url) next[i].favorite = !next[i].favorite
    }
    saveRoomsRequested(next)
  }

  // ------------------------------------------------------------- internals

  property string _loginOutput: ""

  function _applyCallState(logTail) {
    var derived = Model.deriveCallState(logTail, { inCall: inCall, sharing: sharing, muted: muted })
    inCall = derived.inCall
    sharing = derived.sharing
    muted = derived.muted
  }

  function _handleResponse(raw) {
    var response = Model.classifyResponse(raw)
    switch (response.kind) {
    case "logged-out":
      loggedIn = false
      break
    case "logged-in":
      loggedIn = true
      loggingIn = false
      awaitingAuthCode = false
      break
    case "no-call":
      inCall = false
      sharing = false
      break
    case "in-call":
    case "connecting":
    case "joining":
      inCall = true
      break
    case "ending":
      inCall = false
      sharing = false
      break
    case "sharing":
      sharing = true
      break
    case "setting-updated":
      note(response.message)
      refreshData()
      return
    case "invalid-url":
    case "unknown-setting":
    case "error":
      reportError(response.message)
      return
    }
    // A verb that simply worked still prints incidental chatter ("exiting").
    // The label the action already set reads better than echoing that back.
    if (response.kind === "ok" || response.kind === "empty") {
      if (actionStatus === "") note(response.message)
      else statusTimer.restart()
      return
    }
    if (response.message !== "") note(response.message)
  }

  onSettingsChanged: if (probed) refreshData()

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: statusTimer
    interval: 3200
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: settleTimer
    interval: 700
    onTriggered: root.refreshData()
  }

  // A hung client must not wedge the poll loop: every skipped tick is a tick
  // that never runs, so reap anything still going well inside the interval.
  Timer {
    id: watchdog
    interval: 12000
    onTriggered: {
      if (contactsProcess.running) contactsProcess.running = false
      if (settingsProcess.running) settingsProcess.running = false
      if (roomsProcess.running) roomsProcess.running = false
      if (logProcess.running) logProcess.running = false
      root.refreshing = false
    }
  }

  Process {
    id: probeProcess
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.probed = true
      root.refreshing = false
      var path = String(probeOut.text || "").replace(/\s+$/, "")
      var found = exitCode === 0 && path !== ""
      root.installed = found
      root.binaryPath = found ? path : ""
      if (!found) {
        root.daemonRunning = false
        root.loggedIn = false
        root.contacts = []
        root.clientSettings = []
        return
      }
      if (!bannerProcess.running) {
        bannerProcess.command = root.command([])
        bannerProcess.running = true
      }
      root.refreshData()
      if (!watchdog.running) watchdog.restart()
    }
  }

  Process {
    id: bannerProcess
    stdout: StdioCollector { id: bannerOut; waitForEnd: true }
    onExited: root.applyBanner(bannerOut.text)
  }

  Process {
    id: contactsProcess
    stdout: StdioCollector { id: contactsOut; waitForEnd: true }
    stderr: StdioCollector { id: contactsErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      var raw = String(contactsOut.text || "") + String(contactsErr.text || "")
      var parsed = root.generation === "modern" && /^\s*\[/.test(raw)
        ? Model.parseContactsJson(raw)
        : Model.parseContacts(raw)
      root.loggedIn = parsed.loggedIn === true
      root.contacts = Model.sortContacts(parsed.contacts)
    }
  }

  Process {
    id: settingsProcess
    stdout: StdioCollector { id: settingsOut; waitForEnd: true }
    onExited: {
      var parsed = Model.parseSettings(settingsOut.text)
      if (parsed.ok) root.clientSettings = parsed.settings
      root.pendingSetting = ""
    }
  }

  Process {
    id: roomsProcess
    stdout: StdioCollector { id: roomsOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.liveRooms = []
        return
      }
      var parsed = Model.parseRoomsJson(roomsOut.text)
      root.liveRooms = parsed.ok ? parsed.rooms : []
    }
  }

  Process {
    id: daemonProcess
    stdout: StdioCollector { id: daemonOut; waitForEnd: true }
    onExited: root.daemonRunning = Model.daemonSocketPresent(daemonOut.text)
  }

  Process {
    id: logProcess
    stdout: StdioCollector { id: logOut; waitForEnd: true }
    onExited: root._applyCallState(logOut.text)
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var raw = String(actionOut.text || "") + String(actionErr.text || "")
      root.joiningUrl = ""
      root._handleResponse(raw)
      settleTimer.restart()
    }
  }

  Process {
    id: pickerProcess
    stdout: StdioCollector { id: pickerOut; waitForEnd: true }
    stderr: StdioCollector { id: pickerErr; waitForEnd: true }
    onExited: {
      var raw = String(pickerOut.text || "") + String(pickerErr.text || "")
      var contact = root.pendingCall
      root.pendingCall = null
      if (!contact) return
      var number = Model.pickerNumberFor(Model.parseCallPicker(raw), contact)
      if (number === "") {
        root.reportError("Tuple did not offer " + contact.name + " as a call target.")
        return
      }
      actionProcess.command = ["sh", "-c", 'printf "%s\\n" "$2" | "$1" call', "sh",
        root.binaryPath !== "" ? root.binaryPath : "tuple", number]
      actionProcess.running = true
    }
  }

  Process {
    id: personalProcess
    stdout: StdioCollector { id: personalOut; waitForEnd: true }
    stderr: StdioCollector { id: personalErr; waitForEnd: true }
    onExited: {
      var raw = String(personalOut.text || "") + String(personalErr.text || "")
      var url = Model.parsePersonalUrl(raw)
      if (url !== "" && url !== root.personalUrl) {
        root.discoveredPersonalUrl = url
        root.personalUrlDiscovered(url)
      }
      root._handleResponse(raw)
      settleTimer.restart()
    }
  }

  Process {
    id: loginProcess
    stdout: SplitParser { onRead: function(line) { root._loginOutput += line + "\n"; root._consumeLogin() } }
    stderr: SplitParser { onRead: function(line) { root._loginOutput += line + "\n"; root._consumeLogin() } }
    onExited: {
      root._consumeLogin()
      if (root.loginUrl === "" && !root.loggedIn) {
        root.loggingIn = false
        root.reportError(Model.elide(root._loginOutput) || "Sign in did not start")
      }
      settleTimer.restart()
    }
  }

  function _consumeLogin() {
    var parsed = Model.parseLoginOutput(_loginOutput)
    if (parsed.url !== "" && parsed.url !== loginUrl) {
      loginUrl = parsed.url
      awaitingAuthCode = true
      actionStatus = "Finish signing in in your browser"
      openLoginUrl()
    }
    if (parsed.loggedIn) {
      loggedIn = true
      loggingIn = false
      awaitingAuthCode = false
    }
  }

  Process {
    id: installProcess
    stdout: SplitParser { onRead: function(line) { root._consumeInstall(line) } }
    stderr: SplitParser { onRead: function(line) { root._consumeInstall(line) } }
    onExited: function(exitCode) {
      root.installing = false
      if (exitCode !== 0 && root.installStage !== "error") {
        root.installStage = "error"
        root.installMessage = root.installMessage || "Install failed"
        root.reportError(root.installMessage)
      }
      root.refresh()
    }
  }

  function _consumeInstall(line) {
    var event = Model.parseInstallEvent(line)
    if (!event) return
    installStage = event.stage
    installMessage = event.message !== "" ? event.message : Model.installStageLabel(event.stage)
    if (event.version !== "") clientVersion = event.version
    if (event.stage === "error") reportError(installMessage)
    else if (event.stage === "done") note(installMessage)
  }
}
