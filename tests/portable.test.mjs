// Guards the "nothing hardcoded" rule in AGENTS.md: the files users receive
// must not name a machine, a person, or a room.

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const shipped = ["Panel.qml", "TupleStore.qml", "Model.js", "TupleIcon.qml", "qmldir", "manifest.json", "bin/tuple-install"]

const forbidden = [
  [/\/home\/[^/\s"']+/, "a home directory"],
  [/\/usr\/share\//, "a system path"],
  [/\/run\/user\//, "a runtime path"],
  [/[\w.+-]+@(?!example\.com)[\w-]+\.[\w.]+/, "an email address"],
  [/tuple\.app\/c\//, "a room or call link"],
]

for (const file of shipped) {
  test(`${file} hardcodes nothing about a user or machine`, () => {
    const text = readFileSync(join(root, file), "utf8")
    for (const [pattern, what] of forbidden) {
      const match = pattern.exec(text)
      assert.equal(match, null, `${file} contains ${what}: ${match && match[0]}`)
    }
  })
}
