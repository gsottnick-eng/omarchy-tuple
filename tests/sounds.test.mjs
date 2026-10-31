// The call sounds are generated, never hand-edited: tools/make-sounds.py must
// rebuild every committed file byte for byte.

import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const python = spawnSync("python3", ["--version"]).status === 0

test("the committed sounds are what tools/make-sounds.py writes", { skip: !python && "needs python3" }, () => {
  const out = mkdtempSync(join(tmpdir(), "omatuple-sounds-"))
  try {
    const run = spawnSync("python3", ["-I", join(root, "tools", "make-sounds.py"), out])
    assert.equal(run.status, 0, String(run.stderr))
    const built = readdirSync(out).sort()
    assert.deepEqual(readdirSync(join(root, "sounds")).sort(), built)
    for (const name of built)
      assert.ok(readFileSync(join(out, name)).equals(readFileSync(join(root, "sounds", name))), name)
  } finally {
    rmSync(out, { recursive: true, force: true })
  }
})
