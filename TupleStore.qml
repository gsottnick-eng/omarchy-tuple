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
  // Call sounds, one switch each; the panel sets them from its settings.
  property bool soundParticipants: true
  property bool soundCall: true
  property bool soundMute: true
  property bool soundShare: true

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

  readonly property bool busy: actionProcess.running || calling !== "" || installProcess.running
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
    // A line already in flight when Stop closed the stream must not mark the
    // daemon as running again.
    if (stoppedByUser) return
    var s = Model.parseState(line)
    if (!s) return
    var wasInCall = inCall
    var wasMuted = muted
    // The first snapshot only says where things stand; nothing in it is news.
    var heard = stateSeen
    // Lines that arrive within a second of Share are echoes of the start;
    // only a later snapshot means the daemon answers again, i.e. the picker
    // closed — picked or cancelled.
    if (pickerPending && new Date().getTime() - pickerIssuedAt > 1000) {
      pickerPending = false
      pickerTimer.stop()
      if (status.slice(-1) === ".") status = ""
    }
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
    // Mid-call, tell the room who came and went — but only once the change
    // has held long enough not to be a network blip (see participantDebounce).
    // The call's own start and end are announced by onInCallChanged.
    if (s.inCall && !wasInCall) {
      // Everyone already in the call as it starts is announced, not reported.
      announcedParticipants = s.participants.filter(function(p) { return p.connected })
      pendingParticipants = null
      participantDebounce.stop()
    } else if (wasInCall && s.inCall) {
      pendingParticipants = s.participants.filter(function(p) { return p.connected })
      participantDebounce.restart()
    } else if (!s.inCall) {
      announcedParticipants = []
      pendingParticipants = null
      participantDebounce.stop()
      pickerPending = false
      pickerTimer.stop()
    }
    callSounds(heard, wasInCall, wasMuted, s)
    stateSeen = true
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

  function run(args, label, urgent) {
    if (!installed) return
    // The daemon is blocked on the portal picker; piling up commands made
    // things worse in testing. Leaving is always allowed.
    if (pickerPending && !urgent) { note("Tuple is waiting for the share picker…"); return }
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
    if (!inCall || !canShare) return
    if (sharing) { run(["unshare"], "Stopping share…"); return }
    if (pickerPending) return
    // Only check when sharing starts: Xwayland dead earlier in this session
    // never recovers, and the share picker would hang forever.
    var epoch = Model.hyprlandEpoch(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"))
    if (epoch === "") { _share(); return }
    // One-shot check on the shared action queue — not a tuple command, so
    // the command is set directly, without the binary in front. A missing or
    // failing coredumpctl exits nonzero and must never block sharing.
    if (actionProcess.running) return
    _checkingXwayland = true
    progress("")
    actionProcess.command = ["coredumpctl", "list", "--no-legend", "--no-pager", "--since", "@" + epoch, "COREDUMP_COMM=Xwayland"]
    actionProcess.running = true
  }

  function _share() {
    if (pickerPending) return
    run(["share"], "Choose a screen to share in the picker. Tuple pauses until you do.")
    // The daemon's main thread blocks while the portal picker is open, so no
    // other command can run; hold this status until the daemon answers again
    // (the picker closed, picked or cancelled), sharing starts, or 60 s.
    pickerIssuedAt = new Date().getTime()
    pickerPending = true
    pickerTimer.restart()
  }

  function leave() {
    if (inCall || calling !== "") run(["call", "leave"], "Leaving the call…", true)
    calling = ""
    callTimer.stop()
  }

  function accept() {
    run(["call", "accept"], "Answering…")
  }

  // Calls, joins and favorites name a person, a room or a link, so they go to
  // the daemon's API on its socket, never on a `tuple` command line (Model.js,
  // "daemon API"). The state stream shows what happened next.
  function callPerson(person) {
    if (!person || calling !== "" || !_apiReady()) return
    var call = Model.callRequest(person)
    if (call.error) { fail(call.error); return }
    calling = person.name
    progress("Calling " + person.name + "…")
    callTimer.restart()
    api("POST", call.path, call.body, function(reply) {
      // Answered, left, or given up on already: a late answer adds nothing.
      if (root.calling === "") return
      if (root._settled(reply)) return
      root.calling = ""
      callTimer.stop()
    })
  }

  function joinRoom(room) {
    if (room) join(room.slug, "Joining " + room.name + "…")
  }

  function joinUrl(url) {
    var value = String(url || "").trim()
    if (!Model.isJoinableUrl(value)) {
      fail("Paste a full https:// call or room link.")
      return false
    }
    join(Model.joinTarget(value), "Joining…")
    return true
  }

  function join(target, label) {
    if (!_apiReady()) return
    progress(label)
    api("POST", "/call/join", { url: target }, _settled)
  }

  function favoritePerson(person) {
    if (!person || !_apiReady()) return
    if (!/^\d+$/.test(String(person.id))) { fail("Tuple didn't give this person an id."); return }
    api(person.favorite ? "DELETE" : "POST", "/contacts/" + person.id + "/favorite", null, _settled)
  }

  // The rooms stream has no room ids; the room's own record does.
  function favoriteRoom(room) {
    if (!room || !_apiReady()) return
    api("GET", "/rooms/" + encodeURIComponent(room.slug), null, function(reply) {
      var id = reply.body && reply.body.id ? String(reply.body.id) : ""
      if (!root._settled(reply)) return
      if (id === "") { root.fail("Tuple didn't say which room that is."); return }
      root.api(room.favorite ? "DELETE" : "POST", "/rooms/" + encodeURIComponent(id) + "/favorite", null, root._settled)
    })
  }

  function api(method, path, body, done) {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    if (!runtime) { done({ status: 0, body: null }); return }
    apiRequest.createObject(root, {
      path: runtime + "/tuple-0", request: Model.httpRequest(method, path, body), done: done
    })
  }

  // While the share picker is open the daemon answers nothing (see AGENTS.md).
  function _apiReady() {
    if (!installed) return false
    if (pickerPending) { note("Tuple is waiting for the share picker…"); return false }
    return true
  }

  // Reports a failed request; true when it succeeded.
  function _settled(reply) {
    if (reply.status >= 200 && reply.status < 300) {
      if (status.slice(-1) === "…" && calling === "") status = ""
      return true
    }
    fail(Model.apiError(reply))
    return false
  }

  // Links can be private (a sign-in link, a room link), so wl-copy reads them
  // on stdin: every local user can read a process's command line.
  property string _clip: ""
  function copy(value) {
    if (!value) return
    _clip = String(value)
    if (!clipboard.running) { clipboard.stdinEnabled = true; clipboard.running = true }
    note("Copied")
  }

  // ----------------------------------------------------------------- sounds

  property bool stateSeen: false
  // The call has connected at least once, so its end is worth a sound.
  property bool _callConnected: false

  function callSounds(heard, wasInCall, wasMuted, s) {
    if (s.inCall && s.connected && !_callConnected) {
      _callConnected = true
      if (heard && soundCall) play("call-start")
    }
    if (wasInCall && !s.inCall) {
      if (heard && soundCall && _callConnected) play("call-end")
      _callConnected = false
    }
    if (heard && soundMute && wasInCall && s.inCall && s.muted !== wasMuted) play(s.muted ? "mute" : "unmute")
  }

  // Bundled sounds through PipeWire's pw-play, one after another. Only the
  // sound's name reaches the command line.
  property var _sounds: []
  function play(name) {
    if (_sounds.length >= 3) return
    _sounds.push(name)
    if (!player.running) _playNext()
  }
  function _playNext() {
    if (_sounds.length === 0) return
    player.command = ["pw-play", "--volume", "0.6", pluginDir + "/sounds/" + _sounds.shift() + ".wav"]
    player.running = true
  }

  // Alerts name the people in a call, so they reach the notifier on stdin too.
  property var _alerts: []
  function alert(icon, summary, body) {
    _alerts.push(JSON.stringify({ icon: icon, summary: summary, body: body || "" }))
    if (!notifier.running) { notifier.stdinEnabled = true; notifier.running = true }
  }

  // ---------------------------------------------------------------- sign in

  // `tuple login` opens the browser itself and prints the same link, which is
  // kept only so it can be opened again. The code the user pastes back goes
  // to the daemon over its socket (submitCode) and is not kept or shown anywhere.
  function signIn() {
    if (!installed || loginProcess.running) return
    loggingIn = true
    loginUrl = ""
    _loginText = ""
    progress("Opening the sign-in page…")
    loginProcess.command = command(["login"])
    loginProcess.running = true
  }

  // The code goes straight to the daemon over its socket in the user's private
  // runtime directory, never as a command-line argument: `tuple auth CODE`
  // would expose it to other local accounts through /proc (Model.authFrame).
  function submitCode(code) {
    var value = String(code || "").trim()
    var frame = Model.authFrame(value)
    if (frame === "") {
      fail("Paste the authorization code from the sign-in page.")
      return false
    }
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    if (!runtime || authSocket.connected) {
      fail("Couldn't reach Tuple to finish signing in. Click Sign in again.")
      return false
    }
    _authCode = value
    _authFrame = frame
    _authReply = ""
    progress("Finishing sign in…")
    authSocket.path = runtime + "/tuple-0"
    authSocket.connected = true
    return true
  }

  function _finishAuth(failedToConnect) {
    var code = _authCode
    var reply = _authReply.trim()
    _authCode = ""
    _authFrame = ""
    _authReply = ""
    if (failedToConnect) {
      fail("Couldn't reach Tuple to finish signing in. Click Sign in again.")
    } else if (/^error|invalid|failed/i.test(reply)) {
      // Never echo a pasted code back, even if the client quotes it.
      fail(Model.errorMessage(code !== "" ? reply.split(code).join("…") : reply))
    } else if (status.slice(-1) === "…") {
      // Success shows up on the state stream as signed in.
      status = ""
    }
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
  // The prompt is a command-line argument, so it carries no error text: errors
  // can name people or rooms. The agent asks the user what the panel showed.
  function diagnose() {
    if (diagnoseProcess.running) return
    var prompt = "Omatuple, the Tuple bar widget for Omarchy, is misbehaving and I want to know why.\n\n"
      + "  status:     " + summary + "\n"
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
  property string _authFrame: ""
  property string _authReply: ""
  property bool _updating: false

  // True from Share until the client reports sharing or 60 s pass: the daemon
  // is blocked on the portal picker meanwhile.
  property bool pickerPending: false
  property real pickerIssuedAt: 0
  property bool _checkingXwayland: false
  Timer {
    id: pickerTimer
    interval: 60000
    onTriggered: {
      root.pickerPending = false
      if (root.status.slice(-1) === ".") root.status = ""
    }
  }

  // Who we last announced as in the call, and who is waiting to be announced.
  // A change is reported only after it has held for three seconds, so a
  // network blip that flips `connected` away and back says nothing.
  property var announcedParticipants: []
  property var pendingParticipants: null
  Timer {
    id: participantDebounce
    interval: 3000
    onTriggered: {
      var pending = root.pendingParticipants
      root.pendingParticipants = null
      if (pending === null || !root.inCall) return
      var announced = {}
      root.announcedParticipants.forEach(function(p) { announced[p.id] = true })
      var now = {}
      pending.forEach(function(p) { now[p.id] = true })
      var joined = pending.filter(function(p) { return !announced[p.id] })
      var left = root.announcedParticipants.filter(function(p) { return !now[p.id] })
      if (root.callAlerts && root.probed) {
        joined.forEach(function(p) { root.alert("call-start", p.name + " joined the call") })
        left.forEach(function(p) { root.alert("call-stop", p.name + " left the call") })
      }
      if (root.soundParticipants && root.probed) {
        if (joined.length > 0) root.play("joined")
        if (left.length > 0) root.play("left")
      }
      root.announcedParticipants = pending
    }
  }

  onInCallChanged: {
    if (inCall) {
      if (calling !== "" || status.slice(-1) === "…") status = ""
      calling = ""
      callTimer.stop()
      startStreams()
    } else {
      shareStream.running = false
      sharing = false
    }
    if (callAlerts && probed) {
      alert("call-start", inCall ? "Call started" : "Call ended", inCall ? summary : "")
    }
  }

  // Sharing started: the picker is resolved, other commands can run again.
  // A share already running when the shell starts makes no sound.
  onSharingChanged: {
    if (sharing && pickerPending) {
      pickerPending = false
      pickerTimer.stop()
      status = ""
      if (soundShare) play("share-start")
    } else if (!sharing && inCall && soundShare) {
      play("share-stop")
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
    onExited: {
      root.canShare = Model.supportsShare(helpOut.text)
    }
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

  // One request per connection: the daemon answers with a line of text and
  // closes the socket.
  Socket {
    id: authSocket
    parser: SplitParser { onRead: function(line) { root._authReply += line + "\n" } }
    onConnectedChanged: {
      if (connected) {
        write(root._authFrame)
        flush()
      } else if (root._authCode !== "") {
        root._finishAuth(false)
      }
    }
    // The daemon closing the socket after its reply is reported as an error
    // too, so an error only means failure if nothing was answered.
    onError: if (root._authCode !== "") root._finishAuth(root._authReply === "")
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (root._checkingXwayland) {
        root._checkingXwayland = false
        // Exit 0 with output lines naming Xwayland means it crashed this
        // session; anything else (missing coredumpctl, no dumps) never blocks.
        if (exitCode === 0 && Model.xwaylandDead(String(actionOut.text || ""))) {
          root.fail("Xwayland stopped earlier in this session, so screen sharing would hang. Log out and back in, then share again.")
          return
        }
        root._share()
        return
      }
      if (exitCode !== 0) {
        root.pickerPending = false
        pickerTimer.stop()
        root.fail(Model.errorMessage(String(actionErr.text || "") || String(actionOut.text || "")))
      } else if (root.status.slice(-1) === "…") {
        // The state stream shows what changed; the in-flight label is done.
        root.status = ""
      }
      // `start` brings the daemon back; the streams follow it.
      root.startStreams()
    }
  }

  // One request to the daemon's API: write it, collect the whole answer, and
  // hand it over once the daemon closes the connection.
  Component {
    id: apiRequest
    Socket {
      id: apiSocket
      property string request: ""
      property var done: null
      property string reply: ""
      property bool opened: false
      property bool finished: false
      // Unsplit: an answer's body has no trailing newline.
      parser: SplitParser { splitMarker: ""; onRead: function(data) { apiSocket.reply += data } }
      // A daemon that accepts and never answers (a dead Xwayland can do that)
      // still ends the request.
      property Timer deadline: Timer {
        interval: 60000
        running: true
        onTriggered: apiSocket.finish(true)
      }
      onConnectedChanged: {
        if (connected) {
          opened = true
          write(apiSocket.request)
          flush()
        } else {
          finish()
        }
      }
      // The daemon closing after its answer is an error too, and can come before
      // the answer is read: once connected, the disconnect finishes the request.
      onError: if (!opened) finish()
      function finish(timedOut) {
        if (finished) return
        finished = true
        deadline.stop()
        done(timedOut ? { status: 0, body: { error: "Tuple didn't answer." } } : Model.parseHttpResponse(reply))
        // Later: a refused connection finishes while the object is still being built.
        Qt.callLater(apiSocket.destroy)
      }
      Component.onCompleted: connected = true
    }
  }

  // An unanswered call ends without a state change the plugin can see.
  Timer {
    id: callTimer
    interval: 60000
    onTriggered: if (root.calling !== "" && !root.inCall) {
      root.note(root.calling + " didn't pick up")
      root.calling = ""
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
    id: clipboard
    command: ["wl-copy"]
    onStarted: {
      write(root._clip)
      root._clip = ""
      stdinEnabled = false
    }
    // Copied again while wl-copy was still reading: copy the newer value.
    onExited: if (root._clip !== "") { stdinEnabled = true; running = true }
  }

  Process {
    id: player
    onExited: root._playNext()
  }

  Process {
    id: notifier
    command: [root.pluginDir + "/bin/tuple-notify"]
    onStarted: {
      var lines = root._alerts
      root._alerts = []
      lines.forEach(function(line) { write(line + "\n") })
      // End of input: the notifier shows these and exits.
      stdinEnabled = false
    }
    onExited: if (root._alerts.length > 0) { stdinEnabled = true; running = true }
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
