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

test("the people list shows favorites and reachable contacts, and searches the rest", () => {
  const contacts = Model.parseContacts(fixture("contacts.json"))
  const visible = Model.visibleContacts(contacts, "")
  assert.ok(visible.length < contacts.length)
  assert.ok(visible.every((c) => c.favorite || c.status !== "unknown"))
  const offline = contacts.find((c) => !c.favorite && c.status === "unknown")
  assert.deepEqual(Model.visibleContacts(contacts, offline.name.slice(0, 4).toUpperCase()).map((c) => c.id).includes(offline.id), true)
  assert.equal(Model.visibleContacts(contacts, "@example.com").length, contacts.length)
})

test("rooms put the personal room first, then favorites, then occupied", () => {
  const rooms = Model.parseRooms(fixture("rooms.json"))
  assert.equal(rooms.length, 5)
  assert.equal(rooms[0].personal, true)
  assert.equal(rooms[0].name, "Your room", "the personal room has no name of its own")
  assert.ok(rooms[1].favorite && rooms[2].favorite)
  assert.equal(rooms[3].active, true)
  assert.ok(rooms.every((r) => r.url.endsWith("/" + r.slug)))
})

test("the room list shows yours, favorites and rooms in use, and searches the rest", () => {
  const rooms = Model.parseRooms(fixture("rooms.json"))
  const shown = Model.visibleRooms(rooms, "")
  assert.deepEqual(shown.map((r) => r.slug), rooms.filter((r) => r.personal || r.favorite || r.active).map((r) => r.slug))
  const hidden = rooms.find((r) => !shown.includes(r))
  assert.deepEqual(Model.visibleRooms(rooms, hidden.name.toUpperCase()).map((r) => r.slug), [hidden.slug])
  assert.deepEqual(Model.visibleRooms(rooms, "https://tuple.example/c/room-1"), shown, "a pasted link is not a search")
  const contacts = Model.parseContacts(fixture("contacts.json"))
  assert.deepEqual(Model.visibleContacts(contacts, "https://tuple.example/c/room-1"), Model.visibleContacts(contacts, ""))
})

test("JSON and legacy errors both become a plain sentence", () => {
  assert.equal(Model.errorMessage(fixture("error-unauthorized.json")), "not signed in")
  assert.equal(Model.errorMessage(fixture("error-legacy.txt")), "start does not take any command-line args")
  assert.equal(Model.errorMessage("error: no auth session, run 'tuple login' first"), "no auth session, run 'tuple login' first")
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
