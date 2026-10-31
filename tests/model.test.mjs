// Parser tests for Model.js.
//
// The JSON fixtures are real output from Tuple for Linux v2026_10_23.0 with
// every name, email, id, slug and URL replaced by fake values. login.txt is
// rebuilt from the strings in that binary, not captured from a live sign-in.

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")

// Model.js is a QML JS library: `.pragma library` is not valid plain JS, and it
// exports by declaration rather than with `export`. Evaluating it in this realm
// (rather than a vm sandbox) keeps the arrays and objects it returns comparable
// with the ones the assertions build.
const source = readFileSync(join(root, "Model.js"), "utf8").replace(/^\s*\.pragma\s+library\s*$/m, "")
const exported = [...source.matchAll(/^function\s+(\w+)/gm)].map((match) => match[1])
const Model = new Function(`${source}\nreturn { ${exported.join(", ")} }`)()

const fixture = (name) => readFileSync(join(here, "fixtures", name), "utf8")

test("a signed-out state has no user", () => {
  const s = Model.parseState(fixture("state-signed-out.json"))
  assert.equal(s.loggedIn, false)
  assert.equal(s.user, null)
  assert.equal(s.online, false)
  assert.equal(s.inCall, false)
})

test("a signed-in idle state carries the user and no call", () => {
  const s = Model.parseState(fixture("state-idle.json"))
  assert.equal(s.loggedIn, true)
  assert.equal(s.user.name, "Ada")
  assert.equal(s.inCall, false)
  assert.equal(s.version, "v2026_10_23.0")
  assert.equal(s.updateVersion, "")
})

test("the state stream follows a whole call: ringing, connected, mute, unmute, hang up", () => {
  const states = fixture("state-follow-call.jsonl").trim().split("\n").map((l) => Model.parseState(l))
  assert.deepEqual(states.map((s) => s.inCall), [false, true, true, true, true, true, true, true, true, false])
  assert.equal(states[1].connected, false, "ringing is not connected yet")
  assert.equal(states[5].connected, true)
  assert.equal(states[6].muted, true)
  assert.equal(states[7].muted, false)
  assert.equal(states[5].participants.length, 1)
  assert.equal(states[9].callId, "")
})

test("garbage never parses as state", () => {
  assert.equal(Model.parseState("not json"), null)
  assert.equal(Model.parseState("{}"), null)
  assert.equal(Model.parseState(""), null)
})

test("sharing is read from the raw state", () => {
  assert.equal(Model.parseSharing(fixture("state-raw-sharing.json")), true)
  assert.equal(Model.parseSharing(fixture("state-raw-not-sharing.json")), false)
  assert.equal(Model.parseSharing('{"current_call":null}'), false)
  assert.equal(Model.parseSharing("garbage"), null)
})

test("sharing is followed through raw call events, and other events are ignored", () => {
  const event = (type, data) => JSON.stringify({ type, data })
  assert.equal(Model.parseSharing(event("current_call", { local: { share_state: "screen" } })), true)
  assert.equal(Model.parseSharing(event("current_call", { local: { share_state: "audio" } })), false)
  assert.equal(Model.parseSharing(event("current_call", null)), false)
  assert.equal(Model.parseSharing(event("state", { current_call: { local: { share_state: "screen" } } })), true)
  assert.equal(Model.parseSharing(event("session_updated", { id: 1 })), null)
})

test("contacts sort favorites first, then reachable people, then by name", () => {
  const contacts = Model.parseContacts(fixture("contacts.json"))
  assert.equal(contacts.length, 6)
  const firstOther = contacts.findIndex((c) => !c.favorite)
  assert.ok(contacts.slice(0, firstOther).every((c) => c.favorite))
  assert.ok(contacts.slice(firstOther).every((c) => !c.favorite))
  assert.equal(contacts[0].status, "online")
  assert.equal(contacts[0].initials, "GH")
  assert.ok(contacts.some((c) => c.joinable), "a busy contact in a joinable call is marked")
})

test("the people list shows everyone in sorted order, and a search narrows it", () => {
  const contacts = Model.parseContacts(fixture("contacts.json"))
  assert.deepEqual(Model.visibleContacts(contacts, ""), contacts)
  const offline = contacts.find((c) => !c.favorite && c.status === "unknown")
  assert.deepEqual(Model.visibleContacts(contacts, offline.name.slice(0, 4).toUpperCase()).map((c) => c.id), [offline.id])
  assert.equal(Model.visibleContacts(contacts, "@example.com").length, contacts.length)
})

test("rooms put the personal room first, then favorites, then occupied", () => {
  const rooms = Model.parseRooms(fixture("rooms.json"))
  assert.equal(rooms.length, 5)
  assert.deepEqual(rooms.map((r) => r.name), [
    "Your room",
    "Pairing", // favorites A to Z, even when one of them is occupied
    "Standup",
    "Design Review", // occupied
    "Incident"
  ])
  const standup = rooms.find((r) => r.name === "Standup")
  assert.ok(standup.favorite && standup.active, "Standup is an occupied favorite")
  assert.ok(
    rooms.indexOf(standup) > rooms.indexOf(rooms.find((r) => r.name === "Pairing")),
    "an occupied favorite does not jump its fellow favorites"
  )
  assert.ok(rooms.every((r) => r.url.endsWith("/" + r.slug)))
})

test("occupants come from members, and active_call alone never makes a room occupied", () => {
  const rooms = Model.parseRooms(fixture("rooms.json"))
  const design = rooms.find((r) => r.name === "Design Review")
  assert.deepEqual(design.occupants.map((o) => o.name), ["Katherine Johnson", "Donald Knuth"])
  assert.equal(design.active, true)
  const incident = rooms.find((r) => r.name === "Incident")
  assert.deepEqual(incident.occupants, [])
  assert.equal(incident.active, false)
})

test("occupantsLabel lists up to three names, then counts the rest; self reads as You", () => {
  const occupants = (names) => names.map((n) => ({ name: n, email: n.split(" ")[0].toLowerCase() + "@example.com" }))
  const room = (os) => ({ occupants: os })
  assert.equal(Model.occupantsLabel(room(occupants([])), ""), "")
  assert.equal(Model.occupantsLabel(room(occupants(["Ada Lovelace", "Grace Hopper"])), ""), "Ada Lovelace, Grace Hopper")
  const five = occupants(["A", "B", "C", "D", "E"])
  assert.equal(Model.occupantsLabel(room(five), ""), "A, B, C +2")
  assert.equal(
    Model.occupantsLabel(room(occupants(["Ada Lovelace", "Grace Hopper"])), "ada@example.com"),
    "You, Grace Hopper"
  )
})

test("the room list shows every room, and a search narrows it", () => {
  const rooms = Model.parseRooms(fixture("rooms.json"))
  const shown = Model.visibleRooms(rooms, "")
  assert.deepEqual(shown, rooms)
  const plain = rooms.find((r) => !r.personal && !r.favorite && !r.active)
  assert.deepEqual(Model.visibleRooms(rooms, plain.name.toUpperCase()).map((r) => r.slug), [plain.slug])
  assert.deepEqual(Model.visibleRooms(rooms, "https://tuple.example/c/room-1"), shown, "a pasted link is not a search")
  const contacts = Model.parseContacts(fixture("contacts.json"))
  assert.deepEqual(Model.visibleContacts(contacts, "https://tuple.example/c/room-1"), Model.visibleContacts(contacts, ""))
})

test("JSON and legacy errors both become a plain sentence", () => {
  assert.equal(Model.errorMessage(fixture("error-unauthorized.json")), "not signed in")
  assert.equal(Model.errorMessage(fixture("error-legacy.txt")), "start does not take any command-line args")
  assert.equal(Model.errorMessage("error: no auth session, run 'tuple login' first"), "no auth session, run 'tuple login' first")
})

test("the auth request matches what the CLI sends to the daemon, byte for byte", () => {
  // Captured from `tuple auth TESTCODE123` against a stand-in socket.
  const captured = Buffer.from("1100000000000000" + "0200000000000000", "hex").toString("latin1") + "auth\0TESTCODE123\0"
  assert.equal(Model.authFrame("TESTCODE123"), captured)
  assert.equal(Model.authFrame("  TESTCODE123\n"), captured, "surrounding whitespace is trimmed")
})

test("an auth code that could break the frame is refused", () => {
  assert.equal(Model.authFrame(""), "")
  assert.equal(Model.authFrame("two words"), "")
  assert.equal(Model.authFrame("caf\u00e9"), "", "non-ASCII")
  assert.equal(Model.authFrame("x".repeat(101)), "", "too long for a one-byte length")
  assert.ok(Model.authFrame("x".repeat(100)).length > 0)
  assert.ok([...Model.authFrame("a-Z_0.9~+/=")].every((ch) => ch.charCodeAt(0) < 128), "every byte stays ASCII")
})

test("the sign-in URL is the https link in the login instructions", () => {
  assert.equal(Model.parseLoginUrl(fixture("login.txt")), "https://tuple.example/start?code_challenge=fake0000")
  assert.equal(Model.parseLoginUrl("http://insecure.example/start"), "")
})

test("only https links are offered to the client to join", () => {
  assert.equal(Model.isJoinableUrl(" https://tuple.example/c/room-1 "), true)
  assert.equal(Model.isJoinableUrl("http://tuple.example/c/room-1"), false)
  assert.equal(Model.isJoinableUrl("room-1"), false)
})

test("share is offered only while the client still lists it", () => {
  assert.equal(Model.supportsShare(fixture("help.txt")), true)
  assert.equal(Model.supportsShare(fixture("help.txt").replace(/^\s+share\s.*$/m, "")), false)
})

test("install events parse, anything else is ignored", () => {
  assert.deepEqual(Model.parseInstallEvent('{"stage":"done","message":"ok","version":"v1","path":"/x/tuple"}'),
    { stage: "done", message: "ok", version: "v1", path: "/x/tuple" })
  assert.equal(Model.parseInstallEvent("Downloading…"), null)
})

test("boolean settings accept the strings omarchy bar set writes", () => {
  assert.equal(Model.toBool("true", false), true)
  assert.equal(Model.toBool("off", true), false)
  assert.equal(Model.toBool(undefined, true), true)
})

test("the status summary reads in priority order", () => {
  const base = { installed: true, daemonRunning: true, loggedIn: true, inCall: true, muted: true, sharing: false }
  assert.equal(Model.statusSummary({ ...base, installed: false }), "Not installed")
  assert.equal(Model.statusSummary({ ...base, daemonRunning: false }), "Stopped")
  assert.equal(Model.statusSummary({ ...base, loggedIn: false }), "Signed out")
  assert.equal(Model.statusSummary(base), "In a call, muted")
  assert.equal(Model.statusSummary({ ...base, sharing: true }), "Sharing")
  assert.equal(Model.statusSummary({ ...base, inCall: false }), "Ready")
})

test("hyprland epoch and xwayland crash parsing", () => {
  assert.equal(Model.hyprlandEpoch("a1b2c3d4_1769000000_2"), "1769000000")
  assert.equal(Model.hyprlandEpoch(""), "")
  assert.equal(Model.hyprlandEpoch("onlyonepart"), "")
  assert.equal(Model.hyprlandEpoch("hash_notanumber_2"), "")
  assert.equal(Model.xwaylandDead("No coredumps found.\n"), false)
  assert.equal(Model.xwaylandDead(""), false)
  assert.ok(Model.xwaylandDead("Mon Jan  1 00:00:00 2026 12345 1000 1000 11 SIGSEGV /usr/bin/Xwayland"))
})

test("a room whose slug could reach another client endpoint is dropped", () => {
  const rooms = Model.parseRooms([
    { slug: "aB3dEf", name: "Plain" },
    { slug: "room-16", name: "Hyphen" },
    { slug: "../call/1/accept", name: "Path" },
    { slug: "a?b", name: "Query" },
    { slug: "--format", name: "Option-like but harmless after --" },
  ])
  assert.deepEqual(rooms.map((r) => r.slug).sort(), ["--format", "aB3dEf", "room-16"])
})

test("daemon API requests are ASCII HTTP the daemon accepts", () => {
  assert.equal(Model.httpRequest("POST", "/call", { user_id: 1003 }),
    "POST /call HTTP/1.1\r\nHost: tuple\r\nConnection: close\r\nX-Tuple-Client: human\r\n"
    + "Content-Type: application/json\r\nContent-Length: 16\r\n\r\n{\"user_id\":1003}")
  assert.match(Model.httpRequest("DELETE", "/contacts/1/favorite"), /Content-Length: 0\r\n\r\n$/)
  assert.doesNotMatch(Model.httpRequest("GET", "/rooms/a"), /Content-Length/)
  const unicode = Model.httpRequest("POST", "/call/join", { url: "https://tuple.example/r/é😀" })
  assert.match(unicode, /^[\x00-\x7f]*$/, "length in characters is length in bytes")
  assert.equal(JSON.parse(unicode.split("\r\n\r\n")[1]).url, "https://tuple.example/r/é😀")
})

test("daemon API answers parse to a status and body", () => {
  assert.deepEqual(Model.parseHttpResponse("HTTP/1.1 409 Conflict\r\nA: b\r\n\r\n{\"error\":\"declined\"}"),
    { status: 409, body: { error: "declined" } })
  assert.deepEqual(Model.parseHttpResponse("HTTP/1.1 404 Not Found\r\n\r\n"), { status: 404, body: null })
  assert.deepEqual(Model.parseHttpResponse(""), { status: 0, body: null })
  assert.equal(Model.apiError({ status: 0, body: null }), "Couldn't reach Tuple. Is it running?")
  assert.equal(Model.apiError({ status: 409, body: { error: "declined" } }), "declined")
  assert.equal(Model.apiError({ status: 500, body: null }), "Tuple refused the request (500)")
  assert.equal(Model.apiError({ status: 0, body: { error: "Tuple didn't answer." } }), "Tuple didn't answer.")
})

test("calls follow the client's own rules before reaching the daemon", () => {
  const person = (status, joinable, id = 7) => ({ id, name: "Ada Lovelace", status, joinable })
  assert.deepEqual(Model.callRequest(person("online", false)), { path: "/call", body: { user_id: 7 } })
  assert.deepEqual(Model.callRequest(person("unknown", false)), { path: "/call", body: { user_id: 7 } })
  assert.deepEqual(Model.callRequest(person("busy", true)), { path: "/call/join", body: { user_id: 7 } })
  assert.equal(Model.callRequest(person("busy", false)).error, "Ada Lovelace is busy and their call is not joinable")
  assert.equal(Model.callRequest(person("offline", false)).error, "Ada Lovelace is offline")
  assert.ok(Model.callRequest(person("online", false, "7/../x")).error, "only numeric ids reach a path")
})

test("a pasted link joins by slug for /c/ links and whole otherwise, like the client", () => {
  assert.equal(Model.joinTarget("https://tuple.app/c/abc123"), "abc123")
  assert.equal(Model.joinTarget(" https://tuple.app/c/abc123/?x=1#f "), "abc123")
  assert.equal(Model.joinTarget("https://tuple.app/r/abc123"), "https://tuple.app/r/abc123")
  assert.equal(Model.joinTarget("https://example.com/some/path"), "https://example.com/some/path")
})
