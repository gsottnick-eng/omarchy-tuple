// Parser tests for Model.js.
//
// Every fixture under tests/fixtures/ is real output captured from the
// official Tuple for Linux client (v2026_08_20.0), so these assertions track
// the client's actual behaviour rather than an idea of it.

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

const fixture = (name) => readFileSync(join(here, "fixtures", `${name}.txt`), "utf8")

test("detects the installed client generation from its banner", () => {
  const caps = Model.detectCapabilities(fixture("real-banner"))
  assert.equal(caps.version, "v2026_08_20.0")
  assert.equal(caps.generation, "legacy")
  assert.equal(caps.listsRooms, false)
  assert.equal(caps.supportsJson, false)
})

test("claims the richer surface only when the client advertises it", () => {
  const caps = Model.detectCapabilities([
    "Tuple Command-Line Interface v2027_01_01.0",
    "  tuple rooms list         | List your rooms.",
    "  tuple contacts list --format json"
  ].join("\n"))
  assert.equal(caps.generation, "modern")
  assert.equal(caps.listsRooms, true)
  assert.equal(caps.supportsJson, true)
})

test("classifies every response the client gave us", () => {
  const cases = [
    ["real-ls", "logged-out"],
    ["real-new", "logged-out"],
    ["real-join-good", "logged-out"],
    ["real-logout", "logged-out"],
    ["real-join-bad", "invalid-url"],
    ["real-join-roomurl", "invalid-url"],
    ["real-end", "no-call"],
    ["real-mute", "no-call"],
    ["real-share", "no-call"],
    ["real-unknown-verb", "unsupported"],
    ["real-set-unknown", "unknown-setting"],
    ["real-set-ok", "setting-updated"]
  ]
  for (const [name, kind] of cases) {
    assert.equal(Model.classifyResponse(fixture(name)).kind, kind, `${name} should classify as ${kind}`)
  }
})

test("reports which setting the client confirmed", () => {
  assert.equal(Model.classifyResponse(fixture("real-set-ok")).detail, "overlay")
})

test("strips the daemon's startup log out of command output", () => {
  const raw = fixture("real-ls-daemon-restart")
  assert.match(raw, /ConnectionRefused/)
  assert.equal(Model.stripDaemonLog(raw).trim(), "not logged in")
  assert.equal(Model.classifyResponse(raw).kind, "logged-out")
  assert.equal(Model.mentionsDaemonRestart(raw), true)
  assert.equal(Model.mentionsDaemonRestart(fixture("real-ls")), false)
})

test("keeps `tuple off` chatter out of the status line", () => {
  assert.equal(Model.classifyResponse(fixture("real-off")).message, "exiting")
})

test("parses the settings table, including pipes inside descriptions", () => {
  const parsed = Model.parseSettings(fixture("real-settings"))
  assert.equal(parsed.ok, true)
  assert.equal(parsed.settings.length, 5)

  const byKey = Object.fromEntries(parsed.settings.map((s) => [s.key, s]))
  assert.deepEqual(Object.keys(byKey).sort(), [
    "capture", "guest-mode", "overlay", "start-calls-muted", "transcription-model"
  ])

  assert.equal(byKey.overlay.kind, "bool")
  assert.deepEqual(byKey.overlay.options, ["0", "1"])
  assert.equal(byKey.overlay.label, 'Show "overlay" annotation window when sharing screen')
  assert.equal(byKey.overlay.checked, true)

  assert.equal(byKey.capture.kind, "enum")
  assert.deepEqual(byKey.capture.options, ["auto", "x11", "portal"])
  assert.equal(byKey.capture.label, "Screen capture mechanism")

  assert.equal(byKey["transcription-model"].kind, "string")
  assert.equal(byKey["transcription-model"].value, "")
})

test("never mistakes a daemon log line for a setting", () => {
  const parsed = Model.parseSettings(fixture("real-settings-daemon-restart"))
  assert.equal(parsed.settings.length, 5)
  for (const setting of parsed.settings) {
    assert.match(setting.key, /^[a-z][a-z0-9-]*$/)
  }
})

test("cycles setting values the way the client accepts them", () => {
  const parsed = Model.parseSettings(fixture("real-settings"))
  const byKey = Object.fromEntries(parsed.settings.map((s) => [s.key, s]))
  assert.equal(Model.settingToggleValue(byKey.overlay), "0")
  assert.equal(Model.settingToggleValue(byKey["start-calls-muted"]), "1")
  assert.equal(Model.nextEnumValue(byKey.capture), "x11")
  assert.equal(Model.nextEnumValue({ value: "portal", options: ["auto", "x11", "portal"] }), "auto")
})

test("reads the sign-in URL out of the login instructions", () => {
  const parsed = Model.parseLoginOutput(fixture("real-login"))
  assert.equal(parsed.awaitingCode, true)
  assert.equal(parsed.loggedIn, false)
  assert.match(parsed.url, /^https:\/\/production\.tuple\.app\/start\?code_challenge=/)
  assert.ok(!parsed.url.includes(" "), "URL must not absorb surrounding text")
})

test("accepts plausible authorization codes and rejects noise", () => {
  assert.equal(Model.isAuthCode("abc123_-."), true)
  assert.equal(Model.isAuthCode("  code1234  "), true)
  assert.equal(Model.isAuthCode("ab"), false)
  assert.equal(Model.isAuthCode("has space"), false)
})

test("parses a contact list into call targets", () => {
  const parsed = Model.parseContacts([
    "  1) Ada Lovelace <ada@example.com> online",
    "  2) *Grace Hopper <grace@example.com> offline",
    "  3) Alan Turing <alan@example.com>"
  ].join("\n"))

  assert.equal(parsed.loggedIn, true)
  assert.equal(parsed.contacts.length, 3)
  // The printed number is what `tuple call` reads from stdin, so it must be
  // preserved rather than recomputed from array position.
  assert.deepEqual(parsed.contacts.map((c) => c.selector), ["1", "2", "3"])
  assert.equal(parsed.contacts[0].name, "Ada Lovelace")
  assert.equal(parsed.contacts[0].initials, "AL")
  assert.equal(parsed.contacts[0].status, "online")
  assert.equal(parsed.contacts[1].favorite, true)
  assert.equal(parsed.contacts[1].name, "Grace Hopper")
  assert.equal(parsed.contacts[2].status, "")
})

test("reports the signed-out contact list as signed out", () => {
  const parsed = Model.parseContacts(fixture("real-ls"))
  assert.equal(parsed.loggedIn, false)
  assert.equal(parsed.contacts.length, 0)
})

test("sorts favourites first, then by presence, then by name", () => {
  const sorted = Model.sortContacts([
    { name: "Zoe", status: "online", favorite: false },
    { name: "Ada", status: "offline", favorite: false },
    { name: "Bob", status: "online", favorite: false },
    { name: "Yuki", status: "offline", favorite: true }
  ])
  assert.deepEqual(sorted.map((c) => c.name), ["Yuki", "Bob", "Zoe", "Ada"])
})

test("accepts the link formats the client can actually join", () => {
  const url = Model.normalizeRoomInput("https://tuple.app/c/abc123")
  assert.equal(url.ok, true)
  assert.equal(url.slug, "abc123")
  assert.equal(url.name, "abc123")

  const production = Model.normalizeRoomInput("https://production.tuple.app/c/xyz", "Standup")
  assert.equal(production.ok, true)
  assert.equal(production.name, "Standup")

  const bare = Model.normalizeRoomInput("abc123")
  assert.equal(bare.ok, true)
  assert.equal(bare.url, "https://tuple.app/c/abc123")
})

test("explains the /room/ link the client rejects instead of forwarding it", () => {
  const room = Model.normalizeRoomInput("https://tuple.app/room/design")
  assert.equal(room.ok, false)
  assert.equal(room.reason, "room-url")
  assert.match(room.message, /tuple\.app\/c\//)

  // The client's own answer confirms the plugin is right to refuse.
  assert.equal(Model.classifyResponse(fixture("real-join-roomurl")).kind, "invalid-url")
})

test("rejects input that is not a link at all", () => {
  assert.equal(Model.normalizeRoomInput("").reason, "empty")
  assert.equal(Model.normalizeRoomInput("https://example.com/c/x").ok, false)
  assert.equal(Model.normalizeRoomInput("ab").ok, false)
})

test("round-trips saved rooms through settings storage", () => {
  const stored = [
    { url: "https://tuple.app/c/one", name: "One", favorite: true },
    "https://tuple.app/c/two",
    { url: "https://tuple.app/c/one", name: "Duplicate" },
    { url: "not-a-url", name: "Bad" }
  ]
  const rooms = Model.normalizeSavedRooms(stored)
  assert.deepEqual(rooms.map((r) => r.slug), ["one", "two"])
  assert.equal(rooms[0].favorite, true)
  assert.equal(rooms[1].name, "two")

  const serialized = Model.serializeSavedRooms(rooms)
  assert.deepEqual(Model.normalizeSavedRooms(serialized).map((r) => r.url), rooms.map((r) => r.url))
})

test("puts occupied and personal rooms at the top of the list", () => {
  const merged = Model.mergeRooms(
    "https://tuple.app/c/mine",
    Model.normalizeSavedRooms([{ url: "https://tuple.app/c/saved", name: "Saved" }]),
    [Model.makeRoom("https://tuple.app/c/busy", "Busy", { kind: "team", occupants: 2 })]
  )
  assert.deepEqual(merged.map((r) => r.name), ["Busy", "My personal room", "Saved"])
  assert.equal(Model.occupancyLabel(merged[0]), "2 people")
  assert.equal(Model.occupancyLabel(merged[1]), "")
  assert.equal(Model.occupancyLabel({ occupants: 1 }), "1 person")
  assert.equal(Model.occupancyLabel({ occupants: 0 }), "Empty")
})

test("parses the room list a future client would emit", () => {
  const parsed = Model.parseRoomsJson(JSON.stringify([
    { name: "Design", url: "https://tuple.app/c/design", occupants: 1, favorited: true },
    { slug: "backend", kind: "personal", members: [{ name: "Ada" }] }
  ]))
  assert.equal(parsed.ok, true)
  assert.equal(parsed.rooms[0].favorite, true)
  assert.equal(parsed.rooms[1].url, "https://tuple.app/c/backend")
  assert.equal(parsed.rooms[1].occupants, 1)
  assert.equal(Model.parseRoomsJson("not json").ok, false)
})

test("finds the personal room URL in `tuple new` output", () => {
  assert.equal(
    Model.parsePersonalUrl("Personal URL: https://tuple.app/c/ada-personal"),
    "https://tuple.app/c/ada-personal"
  )
  assert.equal(Model.parsePersonalUrl(fixture("real-new")), "")
})

test("derives call state from the daemon log", () => {
  const idle = { inCall: false, sharing: false, muted: false }
  assert.deepEqual(Model.deriveCallState("17:00:00.1|1|1|info|entered room", idle), {
    inCall: true, sharing: false, muted: false
  })
  assert.deepEqual(
    Model.deriveCallState("local user started sharing screen", idle),
    { inCall: true, sharing: true, muted: false }
  )
  // Leaving a call must also clear screen sharing.
  assert.deepEqual(
    Model.deriveCallState("entered room\nlocal user started sharing screen\ncall ended", idle),
    { inCall: false, sharing: false, muted: false }
  )
  assert.equal(Model.deriveCallState("local user ada sending audio: false", idle).muted, true)
  assert.equal(Model.deriveCallState("", { inCall: true, sharing: false, muted: true }).inCall, true)
})

test("detects the daemon by its abstract socket", () => {
  assert.equal(Model.daemonSocketPresent(fixture("proc-net-unix-daemon-up")), true)
  assert.equal(Model.daemonSocketPresent(fixture("proc-net-unix-daemon-down")), false)
  assert.equal(Model.daemonSocketPresent(""), false)
})

test("reads installer progress events", () => {
  const event = Model.parseInstallEvent('{"stage":"download","message":"Downloading Tuple","version":"v1"}')
  assert.equal(event.stage, "download")
  assert.equal(event.version, "v1")
  assert.equal(Model.parseInstallEvent("Downloading Tuple"), null)
  assert.equal(Model.parseInstallEvent('{"no":"stage"}'), null)
  assert.equal(Model.installStageLabel("verify"), "Verifying checksum…")
})

test("summarises status in the order the user cares about", () => {
  assert.equal(Model.statusSummary({ installed: false }), "Tuple is not installed")
  assert.equal(Model.statusSummary({ installed: true, daemonRunning: false }), "Tuple is not running")
  assert.equal(
    Model.statusSummary({ installed: true, daemonRunning: true, loggedIn: false }),
    "Signed out"
  )
  assert.equal(
    Model.statusSummary({ installed: true, daemonRunning: true, loggedIn: true }),
    "Available"
  )
  assert.equal(
    Model.statusSummary({ installed: true, daemonRunning: true, loggedIn: true, inCall: true, sharing: true }),
    "In a call · sharing"
  )
})

test("clamps the refresh interval to a sane range", () => {
  assert.equal(Model.clampInt("45", 20, 5, 600), 45)
  assert.equal(Model.clampInt("1", 20, 5, 600), 5)
  assert.equal(Model.clampInt("nonsense", 20, 5, 600), 20)
})
