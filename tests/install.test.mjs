// bin/tuple-install against a fake curl: only the release shapes Tuple publishes
// get through, since they end up in paths and the panel's JSON events.

import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const installer = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "tuple-install")
const sha = "d266111bc41d5e0592d84c5b84e5ce8ce8bfa41d7a2316a13b8957389fd26e2b"
const url = "https://tuple-client-releases.s3.amazonaws.com/linux/v2026_10_23.0/x86_64/tuple"

function check(release) {
  const bin = mkdtempSync(join(tmpdir(), "fake-curl-"))
  // Prints the release answer, and fails if asked for anything but HTTPS only.
  writeFileSync(join(bin, "curl"), `#!/bin/sh
case " $* " in *" --proto =https --proto-redir =https "*) ;; *) exit 9 ;; esac
cat <<'JSON'
${JSON.stringify(release)}
JSON
`)
  chmodSync(join(bin, "curl"), 0o755)
  const run = spawnSync(installer, ["--check", "--json", "--arch", "x86_64"], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }, encoding: "utf8",
  })
  const events = run.stdout.trim().split("\n").map((line) => JSON.parse(line))
  return events[events.length - 1]
}

test("a well-formed release is accepted", () => {
  assert.deepEqual(check({ version: "v2026_10_23.0", sha256: sha, url }),
    { stage: "done", message: "Latest Tuple for Linux is v2026_10_23.0", version: "v2026_10_23.0" })
})

test("a version that would break the JSON events is refused", () => {
  assert.equal(check({ version: 'v1","stage":"done', sha256: sha, url }).stage, "error")
})

test("a checksum that is not 64 hex digits is refused", () => {
  assert.equal(check({ version: "v1", sha256: "abc", url }).stage, "error")
  assert.equal(check({ version: "v1", sha256: sha.toUpperCase(), url }).stage, "error")
})

test("a download from another host or over HTTP is refused", () => {
  assert.equal(check({ version: "v1", sha256: sha, url: "https://example.com/tuple" }).stage, "error")
  assert.equal(check({ version: "v1", sha256: sha, url: url.replace("https", "http") }).stage, "error")
})
