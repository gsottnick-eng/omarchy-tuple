.pragma library

// Pure helpers for the Tuple CLI's JSON output. No QML imports, so this file
// loads straight into Node for tests. Values coming from QML can be
// QVariantList rather than Array: use toArray, never `instanceof Array`.

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

function toArray(value) {
  if (Array.isArray(value)) return value
  if (value && typeof value === "object" && typeof value.length === "number") {
    var out = []
    for (var i = 0; i < value.length; i++) out.push(value[i])
    return out
  }
  return []
}

function parseJson(raw) {
  try {
    return JSON.parse(text(raw))
  } catch (e) {
    return null
  }
}

function elide(value, max) {
  var limit = max > 0 ? max : 140
  var collapsed = text(value).replace(/\s+/g, " ").trim()
  return collapsed.length > limit ? collapsed.substring(0, limit - 1) + "…" : collapsed
}

// Settings set through `omarchy bar set` arrive as strings unless --json was
// passed, so "true" must read as true.
function toBool(value, fallback) {
  if (value === true || value === false) return value
  if (value === undefined || value === null) return fallback === true
  var t = String(value).trim().toLowerCase()
  if (t === "true" || t === "1" || t === "yes" || t === "on") return true
  if (t === "false" || t === "0" || t === "no" || t === "off" || t === "") return false
  return fallback === true
}

function initialsFor(name) {
  var words = text(name).replace(/[^A-Za-z0-9 ]/g, " ").split(/\s+/)
  var out = ""
  for (var i = 0; i < words.length && out.length < 2; i++) {
    if (words[i] !== "") out += words[i].charAt(0).toUpperCase()
  }
  return out === "" ? "?" : out
}

// ---------------------------------------------------------------- state

// One `tuple state [follow] --format json` snapshot. The client reports a
// signed-out session as user id 0 rather than a null user.
function parseState(raw) {
  var s = typeof raw === "string" ? parseJson(raw) : raw
  if (!s || typeof s !== "object" || !("in_call" in s)) return null
  var user = s.user && s.user.id ? { id: s.user.id, name: text(s.user.short_name), email: text(s.user.email) } : null
  var call = s.in_call && s.call ? s.call : null
  var participants = []
  if (call) {
    var raw_ = toArray(call.participants)
    for (var i = 0; i < raw_.length; i++) {
      participants.push({
        id: raw_[i].id,
        name: text(raw_[i].name),
        muted: raw_[i].muted === true,
        connected: raw_[i].connection_state === "connected"
      })
    }
  }
  return {
    loggedIn: user !== null,
    user: user,
    online: !!(s.connection && s.connection.websocket_state === "connected"),
    inCall: call !== null,
    callId: call ? text(call.call_id) : "",
    muted: call ? call.muted === true : false,
    roomSlug: call ? text(call.active_room_slug) : "",
    participants: participants,
    connected: participants.some(function(p) { return p.connected }),
    version: text(s.app_version),
    updateVersion: text(s.available_update_version)
  }
}

// Screen sharing only shows up in the raw daemon state. `state --raw` prints
// it whole; `state follow --raw` prints {"type","data"} events, a full
// "state" first and then small "current_call" updates. Returns null for a
// line that says nothing about the call.
function parseSharing(raw) {
  var s = parseJson(raw)
  if (!s || typeof s !== "object") return null
  var call
  if (s.type === "state") call = s.data && s.data.current_call
  else if (s.type === "current_call") call = s.data
  else if (s.type !== undefined) return null
  else call = s.current_call
  return !!(call && call.local && call.local.share_state === "screen")
}

// ------------------------------------------------------------- contacts

var STATUS_RANK = { online: 0, available: 0, busy: 1 }

function parseContacts(raw) {
  var list = typeof raw === "string" ? parseJson(raw) : raw
  var out = []
  toArray(list).forEach(function(c) {
    if (!c || c.id === undefined) return
    var name = text(c.full_name) || text(c.email)
    out.push({
      id: c.id,
      name: name,
      email: text(c.email),
      initials: initialsFor(name),
      status: text(c.status) || "unknown",
      favorite: c.favorited === true,
      joinable: !!(c.call && c.call.joinable)
    })
  })
  return out.sort(function(a, b) {
    if (a.favorite !== b.favorite) return a.favorite ? -1 : 1
    var ra = a.status in STATUS_RANK ? STATUS_RANK[a.status] : 2
    var rb = b.status in STATUS_RANK ? STATUS_RANK[b.status] : 2
    if (ra !== rb) return ra - rb
    return a.name.localeCompare(b.name)
  })
}

// Everyone, already sorted favorites and reachable people first; a search
// narrows it by name or email.
function visibleContacts(contacts, query) {
  var q = text(query).trim().toLowerCase()
  if (isJoinableUrl(q)) q = ""
  return toArray(contacts).filter(function(c) {
    return q === "" || c.name.toLowerCase().indexOf(q) !== -1 || c.email.toLowerCase().indexOf(q) !== -1
  })
}

// ---------------------------------------------------------------- rooms

function parseRooms(raw) {
  var list = typeof raw === "string" ? parseJson(raw) : raw
  var out = []
  toArray(list).forEach(function(r) {
    // The client puts the slug into a request path unescaped, so anything but
    // the plain shape Tuple uses could reach another endpoint.
    if (!r || !/^[A-Za-z0-9_-]+$/.test(text(r.slug))) return
    var personal = r.kind === "personal"
    var occupants = toArray(r.members).map(function(m) {
      return { id: m.id, name: text(m.full_name) || text(m.email), email: text(m.email) }
    })
    out.push({
      slug: text(r.slug),
      name: text(r.name) || (personal ? "Your room" : text(r.slug)),
      url: text(r.http_value),
      personal: personal,
      favorite: r.favorited === true,
      occupants: occupants,
      // Occupancy is who is in the room now (members); active_call is not occupancy.
      active: occupants.length > 0
    })
  })
  return out.sort(function(a, b) {
    if (a.personal !== b.personal) return a.personal ? -1 : 1
    // Favorites stay A to Z whoever is in them; occupancy only orders the rest.
    if (a.favorite !== b.favorite) return a.favorite ? -1 : 1
    if (!a.favorite && a.active !== b.active) return a.active ? -1 : 1
    return a.name.localeCompare(b.name)
  })
}

// Who is in a room, for the line under its name: "Ada Lovelace, Grace Hopper +2".
// The signed-in user reads as "You". Empty string when nobody is there.
function occupantsLabel(room, selfEmail) {
  var names = toArray(room && room.occupants).map(function(o) {
    return selfEmail && o.email === selfEmail ? "You" : o.name
  })
  if (names.length <= 3) return names.join(", ")
  return names.slice(0, 3).join(", ") + " +" + (names.length - 3)
}

// Every room, already sorted; a search narrows it by name or slug.
function visibleRooms(rooms, query) {
  var q = text(query).trim().toLowerCase()
  if (isJoinableUrl(q)) q = ""
  return toArray(rooms).filter(function(r) {
    return q === "" || r.name.toLowerCase().indexOf(q) !== -1 || r.slug.toLowerCase().indexOf(q) !== -1
  })
}

// --------------------------------------------------------- commands I/O

// Failed commands print {"error": "..."} on stderr in JSON mode, and plain
// text for the legacy verbs. Either way, return a sentence to show.
function errorMessage(raw) {
  var parsed = parseJson(raw)
  if (parsed && typeof parsed.error === "string") return elide(parsed.error)
  var lines = text(raw).split("\n").map(function(l) {
    // Legacy verbs prefix daemon-log fields: time|pid|tid|level|message
    var parts = l.split("|")
    return parts.length >= 5 ? parts.slice(4).join("|") : l
  }).filter(function(l) { return l.trim() !== "" })
  return elide(lines.join(" ").replace(/^error:\s*/i, ""))
}

// `tuple login` prints instructions with the sign-in URL on its own line.
function parseLoginUrl(raw) {
  var m = /https:\/\/[^\s"'<>]+/.exec(text(raw))
  return m ? m[0] : ""
}

// `tuple auth` only takes the code as a command-line argument, which other
// local accounts can read from /proc while it runs. The plugin sends the same
// request straight to the daemon's socket instead: an 8-byte little-endian
// payload length, an 8-byte argument count, then each argument NUL-terminated
// (captured from the CLI). Quickshell's Socket.write sends text, so every byte
// must stay ASCII: the code must be 1-100 printable ASCII characters, which
// keeps the payload under 128 bytes. Anything else returns "".
function authFrame(code) {
  var c = text(code).trim()
  if (!/^[\x21-\x7e]{1,100}$/.test(c)) return ""
  var payload = "auth\u0000" + c + "\u0000"
  var zeros = "\u0000\u0000\u0000\u0000\u0000\u0000\u0000"
  return String.fromCharCode(payload.length) + zeros + String.fromCharCode(2) + zeros + payload
}

// ------------------------------------------------------------- daemon API
//
// The JSON commands are HTTP requests to the daemon over its socket. Calls,
// joins and favorites name a person, a room or a link, which would be readable
// in /proc as `tuple` arguments, so the plugin sends those requests itself:
// the ones the client sends, minus its lookups by email or slug, since the
// streams already give the plugin the ids.

// One request, ASCII only, so its length in characters is its length in bytes.
function httpRequest(method, path, body) {
  var payload = body === undefined || body === null ? "" : JSON.stringify(body).replace(
    /[\u0080-\uffff]/g, function(c) { return "\\u" + ("000" + c.charCodeAt(0).toString(16)).slice(-4) })
  return method + " " + path + " HTTP/1.1\r\nHost: tuple\r\nConnection: close\r\n"
    + "X-Tuple-Client: human\r\n"
    + (payload !== "" ? "Content-Type: application/json\r\n" : "")
    + (payload !== "" || method !== "GET" ? "Content-Length: " + payload.length + "\r\n" : "")
    + "\r\n" + payload
}

// { status, body }; status 0 when there was no answer at all.
function parseHttpResponse(raw) {
  var s = text(raw)
  var status = /^HTTP\/1\.[01] (\d{3})/.exec(s)
  var split = s.indexOf("\r\n\r\n")
  if (!status || split < 0) return { status: 0, body: null }
  return { status: Number(status[1]), body: parseJson(s.slice(split + 4)) }
}

function apiError(reply) {
  if (reply && reply.body && typeof reply.body.error === "string") return elide(reply.body.error)
  if (!reply || reply.status === 0) return "Couldn't reach Tuple. Is it running?"
  return "Tuple refused the request (" + reply.status + ")"
}

// `tuple call start|join <person>`: the client refuses an offline person, or a
// busy one whose call can't be joined, before asking the daemon.
function callRequest(person) {
  var p = person || {}
  if (!/^\d+$/.test(text(p.id))) return { error: "Tuple didn't give this person an id." }
  if (p.status === "offline") return { error: p.name + " is offline" }
  if (p.status === "busy" && !p.joinable) return { error: p.name + " is busy and their call is not joinable" }
  return { path: p.joinable ? "/call/join" : "/call", body: { user_id: Number(p.id) } }
}

// `tuple call join <link>` sends the slug of a /c/ link and any other link whole.
function joinTarget(url) {
  var value = text(url).trim()
  var slug = /^https:\/\/[^\/?#]+\/c\/([^\/?#]+)/.exec(value)
  return slug ? slug[1] : value
}

// Only the obviously-wrong is rejected here; the client decides the rest.
function isJoinableUrl(value) {
  return /^https:\/\/\S+$/.test(text(value).trim())
}

// `share` and `unshare` are deprecated; offer them only while the client
// still lists them.
function supportsShare(helpText) {
  return /^\s+share\s/m.test(text(helpText))
}


// Hyprland's instance signature is `<hash>_<epoch>_<n>`; the middle field is
// when this compositor session started, in seconds since the epoch. "" when
// the signature doesn't have that shape.
function hyprlandEpoch(signature) {
  var parts = text(signature).split("_")
  return parts.length === 3 && /^\d+$/.test(parts[1]) ? parts[1] : ""
}

// A `coredumpctl list` naming Xwayland means it crashed. "No coredumps
// found." names nothing, so a healthy session reads as false.
function xwaylandDead(output) {
  return text(output).split("\n").some(function(l) { return l.indexOf("Xwayland") !== -1 })
}

function parseInstallEvent(line) {
  var event = parseJson(line)
  if (!event || typeof event !== "object" || typeof event.stage !== "string") return null
  return { stage: event.stage, message: text(event.message), version: text(event.version), path: text(event.path) }
}

function statusSummary(s) {
  if (!s.installed) return "Not installed"
  if (!s.daemonRunning) return "Stopped"
  if (!s.loggedIn) return "Signed out"
  if (s.inCall) return s.sharing ? "Sharing" : (s.muted ? "In a call, muted" : "In a call")
  return "Ready"
}
