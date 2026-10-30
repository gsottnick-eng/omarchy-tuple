// Every `TupleStore.<name>` the panel uses must exist on the store. QML only
// reports a missing one at run time, as a TypeError when it's used: a Share
// button calling an undefined TupleStore.shareFromPanel() once shipped silent.

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const store = readFileSync(join(root, "TupleStore.qml"), "utf8")
const panel = readFileSync(join(root, "Panel.qml"), "utf8")

const declared = new Set([
  ...[...store.matchAll(/^\s*function\s+(\w+)\s*\(/gm)].map((m) => m[1]),
  ...[...store.matchAll(/^\s*(?:readonly\s+)?property\s+\w+\s+(\w+)/gm)].map((m) => m[1]),
  ...[...store.matchAll(/^\s*signal\s+(\w+)/gm)].map((m) => m[1]),
])

test("the store declares what the panel needs at all", () => {
  assert.ok(declared.has("toggleShare") && declared.has("inCall"), "store parsing found the basics")
})

test("every TupleStore member the panel uses exists on the store", () => {
  const used = new Set([...panel.matchAll(/\bTupleStore\.(\w+)/g)].map((m) => m[1]))
  const missing = [...used].filter((name) => !declared.has(name)).sort()
  assert.deepEqual(missing, [], `Panel.qml uses TupleStore members that don't exist: ${missing.join(", ")}`)
})

// Every IPC command the README documents must exist on the panel's IpcHandler:
// leave, accept and join once vanished in an unrelated edit, breaking keybinds.
test("every IPC command in the README exists on the panel", () => {
  const readme = readFileSync(join(root, "README.md"), "utf8")
  const documented = new Set([
    ...[...readme.matchAll(/omarchy-shell io\.github\.gsottnick\.tuple (\w+)/g)].map((m) => m[1]),
    ...[...(readme.match(/^Also (.+)\.$/m)?.[1] ?? "").matchAll(/`(\w+)/g)].map((m) => m[1]),
  ])
  const handler = panel.slice(panel.indexOf("IpcHandler {"), panel.indexOf("BarIconButton {"))
  const verbs = new Set([...handler.matchAll(/^\s*function\s+(\w+)\s*\(/gm)].map((m) => m[1]))
  assert.ok(documented.size >= 10, `found the README's documented commands (${[...documented].join(", ")})`)
  const missing = [...documented].filter((v) => !verbs.has(v)).sort()
  assert.deepEqual(missing, [], `README documents IPC commands the panel lacks: ${missing.join(", ")}`)
})
