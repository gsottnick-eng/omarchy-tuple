pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything that talks to the Tuple client.
//
// A singleton because Omarchy builds a bar widget once per monitor: one set of
// client processes serves every monitor. Nothing is polled. The client pushes
// complete snapshots on three long-lived `follow` streams (state, contacts,
// rooms), plus a raw stream that only runs during a call to see screen
// sharing. Commands go through argument lists, never a shell string, and the
// plugin stores nothing about the account: who is signed in, which rooms
// exist, and how to reach people all come from the client every time.
//
// Every `tuple` command starts the daemon if it is down, the follow streams
// included. "Stop" therefore closes the streams before stopping the daemon,
// and nothing restarts them until "Start".
Singleton {
  id: root

  // Set by Panel from the widget's settings.
  property bool callAlerts: true

  // --------------------------------------------------------------- client
  property bool probed: false
  property bool installed: false
  property string binaryPath: ""
  property bool canShare: false

  // ---------------------------------------------------------------- state
  property bool daemonRunning: false
  property bool stoppedByUser: false
  property var user: null
  property bool loggedIn: false
  property bool online: false
  property bool inCall: false
  property bool connected: false
  property bool muted: false
  property bool sharing: false
  property var participants: []
  property string version: ""
  property string updateVersion: ""
  property var contacts: []
  property var rooms: []

  // --------------------------------------------------------------- sign in
  property bool loggingIn: false
  property string loginUrl: ""

  // ------------------------------------------------------------- feedback
  property string status: ""
  property string error: ""
  property string calling: ""
  property bool installing: false
  property string installMessage: ""

  readonly property bool busy: actionProcess.running || callProcess.running || installProcess.running
  readonly property string summary: Model.statusSummary({
    installed: installed, daemonRunning: daemonRunning, loggedIn: loggedIn,
    inCall: inCall, muted: muted, sharing: sharing
  })
  readonly property string pluginDir: {
    var dir = String(Qt.resolvedUrl("."))
    return (dir.indexOf("file://") === 0 ? dir.substring(7) : dir).replace(/\/$/, "")
  }

  function command(args) {
    return [binaryPath].concat(args)
  }

  // A toast that clears itself.
  function note(message) {
    error = ""
    status = Model.elide(message)
    statusTimer.restart()
  }

  // An in-flight message that stays until its operation finishes.
  function progress(message) {
    statusTimer.stop()
    error = ""
    status = message
  }

  function fail(message) {
    statusTimer.stop()
    status = ""
    error = Model.elide(message) || "Something went wrong"
  }

  // ------------------------------------------------------------ discovery

  // PATH first, then the two places the installer may have put the binary
  // before the shell's PATH knew about them.
  function probe() {
    if (probeProcess.running) return
    var home = Quickshell.env("HOME")
    probeProcess.command = ["sh", "-c",
      'command -v tuple && exit 0; for d in "$1" "$2"; do [ -n "$d" ] && [ -x "$d/tuple" ] && { printf "%s\\n" "$d/tuple"; exit 0; }; done; exit 1',
      "sh", Quickshell.env("XDG_BIN_HOME") || "", home ? home + "/.local/bin" : ""]
    probeProcess.running = true
  }

  function startStreams() {
    if (!installed || stoppedByUser) return
    if (!stateStream.running) {
      stateStream.command = command(["state", "follow", "--format", "json"])
      stateStream.running = true
    }
    if (loggedIn && !contactsStream.running) {
      contactsStream.command = command(["contacts", "follow", "--format", "json"])
      contactsStream.running = true
    }
    if (loggedIn && !roomsStream.running) {
      roomsStream.command = command(["rooms", "follow", "--format", "json"])
      roomsStream.running = true
    }
    if (inCall && !shareStream.running) {
      shareStream.command = command(["state", "follow", "--raw", "--format", "json"])
      shareStream.running = true
    }
  }

  function stopStreams() {
    restartTimer.stop()
    stateStream.running = false
    contactsStream.running = false
    roomsStream.running = false
    shareStream.running = false
  }

  function applyState(line) {
    var s = Model.parseState(line)
    if (!s) return
    restartTimer.interval = 1000
    daemonRunning = true
    user = s.user
    loggedIn = s.loggedIn
    online = s.online
    participants = s.participants
    connected = s.connected
    muted = s.muted
    version = s.version
    updateVersion = s.updateVersion
    inCall = s.inCall
    if (loggedIn && loggingIn) {
      loggingIn = false
      loginUrl = ""
      note("Signed in")
    }
    if (!loggedIn) {
      contacts = []
      rooms = []
    }
    startStreams()
  }

  // ---------------------------------------------------------------- actions

  function run(args, label) {
    if (!installed) return
    if (actionProcess.running) {
      note("Still finishing the last command…")
      return
    }
    progress(label)
    actionProcess.command = command(args)
    actionProcess.running = true
  }

  function start() {
    stoppedByUser = false
    run(["start"], "Starting Tuple…")
  }

  function stop() {
    stoppedByUser = true
    stopStreams()
    daemonRunning = false
    run(["stop"], "Stopping Tuple…")
  }

  function toggleMute() {
    if (inCall) run(["call", muted ? "unmute" : "mute"], muted ? "Unmuting…" : "Muting…")
  }

  function toggleShare() {
    if (inCall && canShare) run([sharing ? "unshare" : "share"], sharing ? "Stopping share…" : "Pick a screen to share…")
  }

  function leave() {
    if (callProcess.running) callProcess.running = false
    if (inCall || calling !== "") run(["call", "leave"], "Leaving the call…")
    calling = ""
  }

  function accept() {
    run(["call", "accept"], "Answering…")
  }

  // `call start` waits until the other side answers, so it gets its own
  // process: the action queue stays free for mute or leave meanwhile.
  function callPerson(person) {
    if (!person || !installed || callProcess.running) return
    calling = person.name
    progress("Calling " + person.name + "…")
    callProcess.command = command(person.joinable
      ? ["call", "join", person.email]
      : ["call", "start", person.email])
    callProcess.running = true
  }

  function joinRoom(room) {
    if (room) run(["rooms", "join", room.slug], "Joining " + room.name + "…")
  }

  function joinUrl(url) {
    var value = String(url || "").trim()
    if (!Model.isJoinableUrl(value)) {
      fail("Paste a full https:// call or room link.")
      return false
    }
    run(["call", "join", value], "Joining…")
    return true
  }

  function favoritePerson(person) {
    if (person) run(["contacts", person.favorite ? "unfavorite" : "favorite", person.email], "")
  }

  function favoriteRoom(room) {
    if (room) run(["rooms", room.favorite ? "unfavorite" : "favorite", room.slug], "")
  }

  function copy(value) {
    if (!value) return
    Quickshell.execDetached(["wl-copy", "--", String(value)])
    note("Copied")
  }

  // ---------------------------------------------------------------- sign in

  // `tuple login` opens the browser itself and prints the same link, which is
  // kept only so it can be opened again. The code the user pastes back goes
  // to `tuple auth` as one argument and is not kept or shown anywhere.
  function signIn() {
    if (!installed || loginProcess.running) return
    loggingIn = true
    loginUrl = ""
    _loginText = ""
    progress("Opening the sign-in page…")
    loginProcess.command = command(["login"])
    loginProcess.running = true
  }

  function submitCode(code) {
    var value = String(code || "").trim()
    if (value === "" || /\s/.test(value)) {
      fail("Paste the authorization code from the sign-in page.")
      return false
    }
    _authCode = value
    run(["auth", value], "Finishing sign in…")
    return true
  }

  function openLoginUrl() {
    if (loginUrl !== "") Qt.openUrlExternally(loginUrl)
  }

  function signOut() {
    run(["logout"], "Signing out…")
  }

  // ------------------------------------------------------------- diagnose

  // Hands the problem to the user's default coding agent the way
  // `omarchy agent crash` does: the facts here, the method in the skill file.
  function diagnose() {
    if (diagnoseProcess.running) return
    var prompt = "Tuplet, the Tuple bar widget for Omarchy, is misbehaving and I want to know why.\n\n"
      + "  status:     " + summary + "\n"
      + "  last error: " + (error || "none") + "\n"
      + "  tuple:      " + (binaryPath || "not found") + " " + version + "\n"
      + "  plugin:     " + pluginDir + "\n\n"
      + "Follow the skill at " + pluginDir + "/agents/diagnose/SKILL.md. "
      + "Ask me what I was doing before changing anything, and never post anything without my approval."
    progress("Opening your agent…")
    diagnoseProcess.command = ["omarchy-agent-prompt", prompt]
    diagnoseProcess.running = true
  }

  // ---------------------------------------------------------------- install

  // An update goes where the current binary already is; a first install uses
  // the installer's own default ($XDG_BIN_HOME or ~/.local/bin).
  function install() {
    if (installProcess.running) return
    if (inCall) {
      fail("Leave the call before updating Tuple.")
      return
    }
    installing = true
    _updating = binaryPath !== ""
    installMessage = "Checking the latest Tuple release…"
    error = ""
    var args = [pluginDir + "/bin/tuple-install", "--json"]
    if (_updating) {
      args.push("--dest", binaryPath.replace(/\/[^\/]*$/, ""))
      stopStreams()
    }
    installProcess.command = args
    installProcess.running = true
  }

  // -------------------------------------------------------------- internals

  property string _loginText: ""
  property string _authCode: ""
  property bool _updating: false

  onInCallChanged: {
    if (inCall) {
      calling = ""
      startStreams()
    } else {
      shareStream.running = false
      sharing = false
    }
    if (callAlerts && probed) {
      Quickshell.execDetached(["notify-send", "-a", "Tuple", "-i", "call-start",
        inCall ? "Call started" : "Call ended", inCall ? summary : ""])
    }
  }

  onLoggedInChanged: if (loggedIn) startStreams()

  Component.onCompleted: probe()

  Timer {
    id: statusTimer
    interval: 3200
    onTriggered: root.status = ""
  }

  // Backs off from 1s to a minute while a stream keeps dying, so a broken
  // client never spins.
  Timer {
    id: restartTimer
    interval: 1000
    onTriggered: {
      interval = Math.min(interval * 2, 60000)
      root.startStreams()
    }
  }

  function _streamEnded() {
    if (!stoppedByUser && installed) restartTimer.restart()
  }

  Process {
    id: probeProcess
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function(exitCode) {
      var path = String(probeOut.text || "").split("\n")[0].trim()
      root.installed = exitCode === 0 && path !== ""
      root.binaryPath = root.installed ? path : ""
      root.probed = true
      if (!root.installed) {
        root.daemonRunning = false
        return
      }
      helpProcess.command = root.command(["--help"])
      helpProcess.running = true
      root.startStreams()
    }
  }

  Process {
    id: helpProcess
    stdout: StdioCollector { id: helpOut; waitForEnd: true }
    onExited: root.canShare = Model.supportsShare(helpOut.text)
  }

  Process {
    id: stateStream
    stdout: SplitParser { onRead: function(line) { root.applyState(line) } }
    onExited: {
      root.daemonRunning = false
      root._streamEnded()
    }
  }

  Process {
    id: contactsStream
    stdout: SplitParser {
      onRead: function(line) {
        var parsed = Model.parseJson(line)
        if (parsed) root.contacts = Model.parseContacts(parsed)
      }
    }
    onExited: if (root.loggedIn) root._streamEnded()
  }

  Process {
    id: roomsStream
    stdout: SplitParser {
      onRead: function(line) {
        var parsed = Model.parseJson(line)
        if (parsed) root.rooms = Model.parseRooms(parsed)
      }
    }
    onExited: if (root.loggedIn) root._streamEnded()
  }

  Process {
    id: shareStream
    stdout: SplitParser {
      onRead: function(line) {
        var sharing = Model.parseSharing(line)
        if (sharing !== null) root.sharing = sharing
      }
    }
    onExited: if (root.inCall) root._streamEnded()
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var code = root._authCode
      root._authCode = ""
      if (exitCode !== 0) {
        var message = Model.errorMessage(String(actionErr.text || "") || String(actionOut.text || ""))
        // Never echo a pasted code back, even if the client quotes it.
        if (code !== "") message = message.split(code).join("…")
        root.fail(message)
      } else if (root.status.slice(-1) === "…") {
        // The state stream shows what changed; the in-flight label is done.
        root.status = ""
      }
      // `start` brings the daemon back; the streams follow it.
      root.startStreams()
    }
  }

  Process {
    id: callProcess
    stderr: StdioCollector { id: callErr; waitForEnd: true }
    onExited: function(exitCode) {
      var who = root.calling
      root.calling = ""
      if (exitCode === 0) root.note("Connected")
      else if (exitCode === 2) root.note((who || "They") + " didn't pick up")
      else if (exitCode > 0) root.fail(Model.errorMessage(callErr.text))
    }
  }

  Process {
    id: loginProcess
    stdout: SplitParser {
      onRead: function(line) {
        root._loginText += line + "\n"
        var url = Model.parseLoginUrl(line)
        if (url !== "" && root.loginUrl === "") {
          // The sign-in section explains the next step itself.
          root.loginUrl = url
          root.status = ""
        }
      }
    }
    stderr: StdioCollector { id: loginErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.loginUrl === "" && !root.loggedIn) {
        root.loggingIn = false
        root.fail(Model.errorMessage(String(loginErr.text || "") || root._loginText) || "Sign in did not start")
      }
    }
  }

  Process {
    id: installProcess
    stdout: SplitParser {
      onRead: function(line) {
        var event = Model.parseInstallEvent(line)
        if (!event) return
        root.installMessage = event.message
        if (event.stage === "error") root.fail(event.message)
      }
    }
    onExited: function(exitCode) {
      root.installing = false
      if (exitCode === 0) root.note(root.installMessage)
      else if (root.error === "") root.fail(root.installMessage || "Install failed")
      // The running daemon is still the old binary; stopping it lets the
      // streams start the new one.
      if (exitCode === 0 && root._updating) {
        root.updateVersion = ""
        stopAfterUpdate.command = root.command(["stop"])
        stopAfterUpdate.running = true
      } else {
        root.probe()
      }
    }
  }

  Process {
    id: diagnoseProcess
    stderr: StdioCollector { id: diagnoseErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.status = ""
      else root.fail((String(diagnoseErr.text || "").trim() || "Couldn't open your agent")
        + ". Pick one with: omarchy default agent <name>")
    }
  }

  Process {
    id: stopAfterUpdate
    onExited: root.probe()
  }
}
