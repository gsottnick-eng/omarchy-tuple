.pragma library

// Pure parsing and normalization for the Tuple client. Everything here is
// side-effect free so the same functions back the QML service and the Node
// test suite.
//
// Two client generations exist. The Linux alpha ("legacy") speaks a small
// verb set and prints human text; the macOS CLI ("modern") supports
// `--format json` and subcommands such as `rooms list`. The service probes
// once and routes through the matching parser.

var CALL_URL_PREFIXES = [
  "https://tuple.app/c/",
  "https://production.tuple.app/c/"
]

var LOGIN_URL_PATTERN = /https:\/\/[^\s"'<>]+/

// ---------------------------------------------------------------- utilities

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

function trimmed(value) {
  return text(value).replace(/^\s+|\s+$/g, "")
}

function lines(raw) {
  return text(raw).split(/\r?\n/)
}

function nonEmptyLines(raw) {
  var out = []
  var all = lines(raw)
  for (var i = 0; i < all.length; i++) {
    var line = trimmed(all[i])
    if (line !== "") out.push(line)
  }
  return out
}

// When the daemon is not running the CLI revives it and prints its own
// startup log to the same stream as the answer, e.g.
//   17:00:28.608|8245|8245|info|connect failed with ConnectionRefused
// Those lines are pipe-delimited just like `tuple settings` output, so they
// have to come out before anything else looks at the text.
var DAEMON_LOG_LINE = /^\d{1,2}:\d{2}:\d{2}\.\d+\|\d+\|/

function stripDaemonLog(raw) {
  var out = []
  var all = lines(raw)
  for (var i = 0; i < all.length; i++) {
    if (!DAEMON_LOG_LINE.test(trimmed(all[i]))) out.push(all[i])
  }
  return out.join("\n")
}

// The CLI restarts a dead daemon on demand, so this is a report about the
// moment before the command ran, not a lasting state.
function mentionsDaemonRestart(raw) {
  return /connect failed with ConnectionRefused/i.test(text(raw))
}

// The daemon listens on an abstract socket, which makes /proc/net/unix a
// dependency-free liveness check. Process lookup does not work: the daemon
// re-execs under the argv of whichever command spawned it.
function daemonSocketPresent(procNetUnix) {
  return /@tuple-daemon\b/.test(text(procNetUnix))
}

// Lists that arrive from QML settings are QVariantLists, which are array-like
// but not JS arrays, so Array.isArray alone would silently drop saved rooms.
function toArray(value) {
  if (Array.isArray(value)) return value
  if (value && typeof value === "object" && typeof value.length === "number") {
    var out = []
    for (var i = 0; i < value.length; i++) out.push(value[i])
    return out
  }
  return []
}

function elide(value, max) {
  var limit = max > 0 ? max : 140
  var collapsed = trimmed(text(value).replace(/\s+/g, " "))
  return collapsed.length > limit ? collapsed.substring(0, limit - 1) + "…" : collapsed
}

function initialsFor(name, email) {
  var source = trimmed(name) || trimmed(email)
  if (source === "") return "?"
  var words = source.replace(/[^A-Za-z0-9 ]/g, " ").split(/\s+/)
  var out = ""
  for (var i = 0; i < words.length && out.length < 2; i++) {
    if (words[i] !== "") out += words[i].charAt(0).toUpperCase()
  }
  return out === "" ? source.charAt(0).toUpperCase() : out
}

// ------------------------------------------------------------- capabilities

// The banner `tuple` prints with no arguments lists the verbs the installed
// client understands. The modern CLI documents `rooms` and `--format`, so the
// richer surface is only claimed when the client actually advertises it.
function detectCapabilities(banner) {
  var raw = text(banner)
  var hasRooms = /^\s*tuple\s+rooms\b/m.test(raw) || /\brooms\s+list\b/.test(raw)
  var hasJson = /--format\b/.test(raw)
  var hasState = /^\s*tuple\s+state\b/m.test(raw)
  var version = ""
  var versionMatch = raw.match(/Tuple Command-Line Interface\s+(\S+)/)
  if (versionMatch) version = versionMatch[1]
  var generation = (hasRooms && hasJson) ? "modern" : "legacy"
  return {
    generation: generation,
    version: version,
    listsRooms: hasRooms,
    supportsJson: hasJson,
    reportsState: hasState
  }
}

// ---------------------------------------------------------------- responses

// Every legacy verb answers with one line of prose. These are the exact
// strings the client ships, so the panel can turn a command result into
// state instead of guessing.
var RESPONSE_RULES = [
  { pattern: /\bnot logged in\b/i,                   kind: "logged-out" },
      { pattern: /\balready logged in\b/i,               kind: "logged-in" },
      { pattern: /\balready logged out\b/i,              kind: "logged-out" },
  { pattern: /\blogout initiated\b/i,                kind: "logged-out" },
  { pattern: /\bstarting new call with personal url\b/i, kind: "joining" },
  { pattern: /\balready not in a call\b/i,           kind: "no-call" },
  { pattern: /\bcan't (?:mute|unmute|share|unshare)\b[^.]*\bnot in a call\b/i, kind: "no-call" },
  { pattern: /\bcan't join call, already in a call\b/i, kind: "in-call" },
  { pattern: /\balready sharing screen\b/i,          kind: "sharing" },
  { pattern: /\balready joining this call\b/i,       kind: "joining" },
  { pattern: /\bcall connecting\b/i,                 kind: "connecting" },
  { pattern: /\bjoining call\b/i,                    kind: "joining" },
  { pattern: /\bending call\b/i,                     kind: "ending" },
  { pattern: /\berror: invalid call url\b/i,         kind: "invalid-url" },
  { pattern: /\berror: unknown command\b/i,          kind: "unsupported" },
  { pattern: /\berror: unknown setting\b/i,          kind: "unknown-setting" },
  { pattern: /\bsetting '([^']+)' updated\b/i,       kind: "setting-updated" },
  { pattern: /\berror\b/i,                           kind: "error" }
]

function classifyResponse(raw) {
  var body = trimmed(stripDaemonLog(raw))
  for (var i = 0; i < RESPONSE_RULES.length; i++) {
    var rule = RESPONSE_RULES[i]
    var match = body.match(rule.pattern)
    if (match) {
      return {
        kind: rule.kind,
        message: elide(body),
        detail: match.length > 1 ? match[1] : ""
      }
    }
  }
  return { kind: body === "" ? "empty" : "ok", message: elide(body), detail: "" }
}

// --------------------------------------------------------------- contacts

// The client prints contacts two different ways, and the difference matters.
//
//   `tuple ls`     ->  "  {} {} <{}> [{}]{}"   id, name, email, status, extra
//   `tuple call`   ->  "  {}) {} <{}>"         a numbered picker
//
// `tuple favorite` takes the id from the first form; `tuple call` reads the
// number from the second form on stdin. Neither value can substitute for the
// other, so both are parsed separately.
var LIST_ROW = /^\s*(\S+)\s+(.*?)\s*<([^>]*)>\s*\[([^\]]*)\]\s*(.*)$/
var PICKER_ROW = /^\s*(\d+)\)\s*(.*?)\s*<([^>]*)>\s*(.*)$/

function makeContact(selector, name, email, status, extra) {
  var rawName = trimmed(name)
  var trailing = trimmed(extra)
  var favorite = /^[*★]/.test(rawName) || /[*★]/.test(trailing) || /favorit/i.test(trailing)
  var cleanName = rawName.replace(/^[*★]\s*/, "")
  return {
    selector: trimmed(selector),
    name: cleanName === "" ? trimmed(email) : cleanName,
    email: trimmed(email),
    status: trimmed(status).toLowerCase(),
    favorite: favorite,
    initials: initialsFor(cleanName, email)
  }
}

function parseContacts(raw) {
  var response = classifyResponse(raw)
  if (response.kind === "logged-out") {
    return { ok: false, loggedIn: false, contacts: [], message: response.message }
  }

  var clean = stripDaemonLog(raw)
  var contacts = []
  var all = lines(clean)
  for (var i = 0; i < all.length; i++) {
    var listed = all[i].match(LIST_ROW)
    if (listed) {
      contacts.push(makeContact(listed[1], listed[2], listed[3], listed[4], listed[5]))
      continue
    }
    // Accept picker rows too, so a picker captured by mistake still renders.
    var picked = all[i].match(PICKER_ROW)
    if (picked) contacts.push(makeContact(picked[1], picked[2], picked[3], picked[4], ""))
  }

  var waiting = /waiting for contacts/i.test(clean)
  return {
    ok: contacts.length > 0 || !waiting,
    loggedIn: true,
    waiting: waiting,
    contacts: contacts,
    message: contacts.length === 0 ? response.message : ""
  }
}

// Modern CLI: `tuple contacts list --format json`.
function parseContactsJson(raw) {
  var parsed = safeJson(raw)
  if (!parsed.ok || !Array.isArray(parsed.value)) {
    return { ok: false, loggedIn: true, contacts: [], message: parsed.message || "Unreadable contact list" }
  }
  var contacts = []
  for (var i = 0; i < parsed.value.length; i++) {
    var entry = parsed.value[i] || {}
    var name = trimmed(entry.full_name || entry.name || entry.short_name)
    var email = trimmed(entry.email)
    contacts.push({
      selector: email || name,
      name: name || email,
      email: email,
      status: trimmed(entry.status || entry.presence).toLowerCase(),
      favorite: entry.favorited === true || entry.favorite === true,
      initials: initialsFor(name, email)
    })
  }
  return { ok: true, loggedIn: true, contacts: contacts, message: "" }
}

// `tuple call` prints its picker and then reads a number from stdin. Running
// it once with no input yields the authoritative numbering, so the number sent
// on the second run is read from the client rather than assumed to match the
// order of `tuple ls`.
function parseCallPicker(raw) {
  var out = []
  var all = lines(stripDaemonLog(raw))
  for (var i = 0; i < all.length; i++) {
    var match = all[i].match(PICKER_ROW)
    if (!match) continue
    out.push({
      number: match[1],
      name: trimmed(match[2]).replace(/^[*★]\s*/, ""),
      email: trimmed(match[3])
    })
  }
  return out
}

function pickerNumberFor(entries, contact) {
  if (!contact) return ""
  var list = toArray(entries)
  var email = trimmed(contact.email).toLowerCase()
  var name = trimmed(contact.name).toLowerCase()
  for (var i = 0; i < list.length; i++) {
    if (email !== "" && trimmed(list[i].email).toLowerCase() === email) return list[i].number
  }
  for (var j = 0; j < list.length; j++) {
    if (name !== "" && trimmed(list[j].name).toLowerCase() === name) return list[j].number
  }
  return ""
}

function sortContacts(contacts) {
  var rank = { online: 0, available: 0, busy: 1, offline: 3 }
  var list = toArray(contacts).slice()
  list.sort(function(a, b) {
    if (a.favorite !== b.favorite) return a.favorite ? -1 : 1
    var ra = rank[a.status] === undefined ? 2 : rank[a.status]
    var rb = rank[b.status] === undefined ? 2 : rank[b.status]
    if (ra !== rb) return ra - rb
    return text(a.name).toLowerCase() < text(b.name).toLowerCase() ? -1 : 1
  })
  return list
}

// --------------------------------------------------------------- settings

// `tuple settings` prints `name | value | description (allowed|values)`.
// The allowed-value hint drives the control type, so a setting Tuple adds
// later renders correctly without a plugin change.
function parseSettings(raw) {
  var response = classifyResponse(raw)
  if (response.kind === "unsupported") return { ok: false, settings: [], message: response.message }

  var settings = []
  var all = lines(stripDaemonLog(raw))
  for (var i = 0; i < all.length; i++) {
    var parts = all[i].split("|")
    if (parts.length < 2) continue
    var key = trimmed(parts[0])
    // Setting names are lowercase kebab-case. Anything else on a
    // pipe-delimited line is output that does not belong to the table.
    if (!/^[a-z][a-z0-9-]*$/.test(key)) continue
    var value = trimmed(parts[1])
    var description = trimmed(parts.slice(2).join("|"))
    settings.push(describeSetting(key, value, description))
  }
  return { ok: settings.length > 0, settings: settings, message: settings.length ? "" : response.message }
}

function describeSetting(key, value, description) {
  var label = description
  var options = []
  var kind = "string"

  // Trailing parenthetical enumerates the accepted values, e.g. `(0|1)`.
  var hint = description.match(/\(([^()]*\|[^()]*)\)\s*$/)
  if (hint) {
    label = trimmed(description.substring(0, hint.index))
    var raw = hint[1].split("|")
    for (var i = 0; i < raw.length; i++) {
      var option = trimmed(raw[i])
      if (option !== "") options.push(option)
    }
    var isBool = options.length === 2 && options.indexOf("0") !== -1 && options.indexOf("1") !== -1
    kind = isBool ? "bool" : "enum"
  }

  return {
    key: key,
    value: value,
    kind: kind,
    options: options,
    label: label === "" ? key : label,
    description: description,
    checked: kind === "bool" && value === "1"
  }
}

function settingToggleValue(setting) {
  return setting && setting.value === "1" ? "0" : "1"
}

function nextEnumValue(setting) {
  var options = setting ? toArray(setting.options) : []
  if (options.length === 0) return ""
  var at = options.indexOf(setting.value)
  return options[(at + 1) % options.length]
}

// ------------------------------------------------------------------- rooms

// Tuple rooms are permanent call URLs. The Linux client only accepts the
// canonical `/c/` form, so a room the user pastes is validated against the
// exact prefixes the client enforces rather than being sent blind.
function isCallUrl(value) {
  var url = trimmed(value)
  for (var i = 0; i < CALL_URL_PREFIXES.length; i++) {
    if (url.indexOf(CALL_URL_PREFIXES[i]) === 0 && url.length > CALL_URL_PREFIXES[i].length) return true
  }
  return false
}

function callUrlSlug(value) {
  var url = trimmed(value)
  for (var i = 0; i < CALL_URL_PREFIXES.length; i++) {
    if (url.indexOf(CALL_URL_PREFIXES[i]) === 0) return url.substring(CALL_URL_PREFIXES[i].length)
  }
  return ""
}

// Accepts a full call URL or a bare room id and returns the joinable URL.
// A `/room/<slug>` link is reported specifically because the current Linux
// client rejects it and the user needs to copy the room's call URL instead.
function normalizeRoomInput(value, name) {
  var input = trimmed(value)
  if (input === "") return { ok: false, reason: "empty", message: "Paste a room link or id." }

  var roomStyle = input.match(/^https:\/\/(?:production\.)?tuple\.app\/room\/([A-Za-z0-9_./-]+)$/)
  if (roomStyle) {
    return {
      ok: false,
      reason: "room-url",
      message: "This Tuple client can't join /room/ links yet. Open the room in Tuple and copy its call link (tuple.app/c/…)."
    }
  }

  if (isCallUrl(input)) {
    var slug = callUrlSlug(input)
    return { ok: true, url: input, slug: slug, name: trimmed(name) || slug }
  }

  if (/^[A-Za-z0-9_-]{4,}$/.test(input)) {
    var url = CALL_URL_PREFIXES[0] + input
    return { ok: true, url: url, slug: input, name: trimmed(name) || input }
  }

  return {
    ok: false,
    reason: "invalid",
    message: "Enter a Tuple call link (https://tuple.app/c/…) or the id at the end of one."
  }
}

function makeRoom(url, name, options) {
  var extra = options || {}
  var slug = callUrlSlug(url)
  return {
    id: trimmed(url),
    url: trimmed(url),
    slug: slug,
    name: trimmed(name) || slug || "Room",
    kind: extra.kind || "saved",
    favorite: extra.favorite === true,
    occupants: extra.occupants === undefined ? -1 : extra.occupants,
    members: toArray(extra.members)
  }
}

function normalizeSavedRooms(stored) {
  var out = []
  var seen = {}
  var list = toArray(stored)
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    var url = ""
    var name = ""
    var favorite = false
    if (typeof entry === "string") {
      url = trimmed(entry)
    } else if (entry) {
      url = trimmed(entry.url)
      name = trimmed(entry.name)
      favorite = entry.favorite === true
    }
    if (!isCallUrl(url) || seen[url]) continue
    seen[url] = true
    out.push(makeRoom(url, name, { kind: "saved", favorite: favorite }))
  }
  return out
}

function serializeSavedRooms(rooms) {
  var out = []
  var list = toArray(rooms)
  for (var i = 0; i < list.length; i++) {
    var room = list[i]
    if (!room || room.kind !== "saved" || !isCallUrl(room.url)) continue
    out.push({ url: room.url, name: room.name, favorite: room.favorite === true })
  }
  return out
}

// Modern CLI: `tuple rooms list --format json`.
function parseRoomsJson(raw) {
  var parsed = safeJson(raw)
  if (!parsed.ok || !Array.isArray(parsed.value)) {
    return { ok: false, rooms: [], message: parsed.message || "Unreadable room list" }
  }
  var rooms = []
  for (var i = 0; i < parsed.value.length; i++) {
    var entry = parsed.value[i] || {}
    var url = trimmed(entry.url || entry.join_url)
    var members = toArray(entry.members)
    var occupants = typeof entry.occupants === "number"
      ? entry.occupants
      : (typeof entry.member_count === "number" ? entry.member_count : members.length)
    rooms.push(makeRoom(url || (CALL_URL_PREFIXES[0] + trimmed(entry.slug)), entry.name || entry.slug, {
      kind: entry.kind === "personal" ? "personal" : "team",
      favorite: entry.favorited === true,
      occupants: occupants,
      members: members
    }))
  }
  return { ok: true, rooms: rooms, message: "" }
}

function mergeRooms(personalUrl, savedRooms, liveRooms) {
  var out = []
  var seen = {}

  function push(room) {
    if (!room || !room.url || seen[room.url]) return
    seen[room.url] = true
    out.push(room)
  }

  if (isCallUrl(personalUrl)) {
    push(makeRoom(personalUrl, "My personal room", { kind: "personal" }))
  }
  var live = toArray(liveRooms)
  for (var i = 0; i < live.length; i++) push(live[i])
  var saved = toArray(savedRooms)
  for (var j = 0; j < saved.length; j++) push(saved[j])

  out.sort(function(a, b) {
    if ((a.occupants > 0) !== (b.occupants > 0)) return a.occupants > 0 ? -1 : 1
    if (a.favorite !== b.favorite) return a.favorite ? -1 : 1
    var rank = { personal: 0, team: 1, saved: 2 }
    var ra = rank[a.kind] === undefined ? 3 : rank[a.kind]
    var rb = rank[b.kind] === undefined ? 3 : rank[b.kind]
    if (ra !== rb) return ra - rb
    return text(a.name).toLowerCase() < text(b.name).toLowerCase() ? -1 : 1
  })
  return out
}

function occupancyLabel(room) {
  if (!room || room.occupants < 0) return ""
  if (room.occupants === 0) return "Empty"
  return room.occupants === 1 ? "1 person" : room.occupants + " people"
}

// ------------------------------------------------------------------- login

// `tuple login` prints instructions containing the browser URL; `tuple auth`
// finishes with the code the browser hands back.
function parseLoginOutput(raw) {
  var body = stripDaemonLog(raw)
  var url = ""
  var lines = nonEmptyLines(body)
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(LOGIN_URL_PATTERN)
    if (match && match[0].indexOf("tuple.app") !== -1) {
      url = match[0].replace(/[.,)]+$/, "")
      break
    }
  }
  return {
    url: url,
    awaitingCode: url !== "" || /authorization code/i.test(body),
    loggedIn: /already logged in|logged in successfully/i.test(body),
    message: elide(body)
  }
}

function isAuthCode(value) {
  return /^[A-Za-z0-9._-]{4,}$/.test(trimmed(value))
}

function parsePersonalUrl(raw) {
  var match = text(raw).match(/personal url:\s*(\S+)/i)
  if (match && isCallUrl(match[1])) return match[1]
  var any = text(raw).match(/https:\/\/(?:production\.)?tuple\.app\/c\/\S+/)
  return any ? any[0].replace(/[.,)]+$/, "") : ""
}

// -------------------------------------------------------------- call state

// The legacy client has no read-only status verb, so live call state is
// derived from the daemon log the client already writes. Only high-confidence
// markers are used, and an explicit user action always wins.
var LOG_MARKERS = [
  { pattern: /entered room|call connected|joined call/i,             set: { inCall: true } },
  { pattern: /peer left call|call ended|synthesizing room leave/i,   set: { inCall: false, sharing: false } },
  { pattern: /local user started sharing screen/i,                   set: { inCall: true, sharing: true } },
  { pattern: /local user stopped sharing screen/i,                   set: { sharing: false } },
  { pattern: /local user \S+ sending audio: false/i,                 set: { muted: true } },
  { pattern: /local user \S+ sending audio: true/i,                  set: { muted: false } }
]

function deriveCallState(logTail, previous) {
  var state = {
    inCall: previous ? previous.inCall === true : false,
    sharing: previous ? previous.sharing === true : false,
    muted: previous ? previous.muted === true : false
  }
  var all = lines(logTail)
  for (var i = 0; i < all.length; i++) {
    for (var r = 0; r < LOG_MARKERS.length; r++) {
      if (!LOG_MARKERS[r].pattern.test(all[i])) continue
      var set = LOG_MARKERS[r].set
      for (var key in set) state[key] = set[key]
    }
  }
  if (!state.inCall) {
    state.sharing = false
  }
  return state
}

// ------------------------------------------------------------------ install

// The installer emits one JSON object per line so progress can be shown
// without scraping human text.
function parseInstallEvent(line) {
  var parsed = safeJson(line)
  if (!parsed.ok || !parsed.value || typeof parsed.value !== "object") return null
  var event = parsed.value
  if (typeof event.stage !== "string") return null
  return {
    stage: event.stage,
    message: text(event.message),
    version: text(event.version),
    path: text(event.path),
    percent: typeof event.percent === "number" ? event.percent : -1,
    ok: event.ok !== false
  }
}

var INSTALL_STAGE_LABELS = {
  "resolve": "Checking the latest release…",
  "download": "Downloading Tuple…",
  "verify": "Verifying checksum…",
  "install": "Installing…",
  "done": "Tuple installed",
  "error": "Install failed"
}

function installStageLabel(stage) {
  var label = INSTALL_STAGE_LABELS[text(stage)]
  return label === undefined ? "Working…" : label
}

// --------------------------------------------------------------------- misc

function safeJson(raw) {
  var body = trimmed(raw)
  if (body === "") return { ok: false, value: null, message: "Empty response" }
  try {
    return { ok: true, value: JSON.parse(body), message: "" }
  } catch (error) {
    return { ok: false, value: null, message: "Invalid JSON: " + elide(String(error), 80) }
  }
}

function statusSummary(state) {
  var s = state || {}
  if (!s.installed) return "Tuple is not installed"
  if (!s.daemonRunning) return "Tuple is not running"
  if (!s.loggedIn) return "Signed out"
  if (s.inCall) return s.sharing ? "In a call · sharing" : "In a call"
  return "Available"
}

function presenceGlyphColorKey(state) {
  var s = state || {}
  if (!s.installed || !s.daemonRunning) return "idle"
  if (!s.loggedIn) return "idle"
  if (s.inCall) return "active"
  return "ready"
}

function clampInt(value, fallback, min, max) {
  var n = parseInt(String(value), 10)
  if (!isFinite(n)) n = fallback
  if (n < min) n = min
  if (n > max) n = max
  return n
}

// ------------------------------------------------------------------- audio

// Tuple's Linux client exposes no audio settings at all -- its whole surface
// is the five in `tuple settings` -- so device choice has to come from
// PipeWire instead. `pactl -f json list sinks|sources` is the one machine
// readable form available without adding a dependency.
function parseAudioDevices(raw, kind) {
  var list
  try {
    list = JSON.parse(String(raw || ""))
  } catch (e) {
    return []
  }
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var device = list[i]
    if (!device || typeof device.name !== "string" || device.name === "") continue
    // Every sink has a matching ".monitor" source that loops its output back.
    // Nobody choosing a microphone means one of those.
    if (kind === "source" && device.monitor_source) continue
    out.push({
      name: device.name,
      label: String(device.description || device.name)
    })
  }
  out.sort(function (a, b) { return a.label.localeCompare(b.label) })
  return out
}

// `pactl get-default-sink` answers with the bare name and nothing else, but
// the daemon can still interleave a blank line or a warning.
function parseDefaultDevice(raw) {
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line !== "" && line.indexOf(" ") === -1) return line
  }
  return ""
}

// `pactl get-default-sink; pactl get-default-source` run back to back, so the
// answer is two bare names in order.
function parseDefaultPair(raw) {
  var lines = String(raw || "").split("\n")
  var names = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line !== "" && line.indexOf(" ") === -1) names.push(line)
  }
  return { sink: names.length > 0 ? names[0] : "", source: names.length > 1 ? names[1] : "" }
}

function activeDeviceLabel(devices, name) {
  var list = toArray(devices)
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].name === name) return list[i].label
  }
  return ""
}
