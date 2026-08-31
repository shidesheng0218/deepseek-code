#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$root/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
"$root/scripts/build-agent-sidecar.sh" >/dev/null

node - "$binary" "$root" <<'NODE'
// Regression test: streamModel() previously declared `let turnSequence = 0` inside
// the per-call generator function, so every model round-trip within the same turn
// recorded turnSequence:0 -- there was no way to tell round-trip #1 from #2 in the
// same session's model_stream_recorded events. Fixed by counting existing
// model_stream_recorded events for the session before each recording. This drives a
// turn that makes two real model round-trips (apply_patch, then final text) and
// asserts the two resulting model_stream_recorded events get distinct, increasing
// turnSequence values.
const assert = require("assert")
const http = require("http")
const { spawn } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

const [binary, root] = process.argv.slice(2)
const projectPath = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-turnseq-project-"))
const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-turnseq-events-"))
fs.writeFileSync(path.join(projectPath, "README.md"), "before\n")

let modelCalls = 0
const provider = http.createServer((request, response) => {
  let body = ""
  request.on("data", (chunk) => { body += chunk })
  request.on("end", () => {
    modelCalls += 1
    response.writeHead(200, { "content-type": "text/event-stream" })
    if (modelCalls === 1) {
      const argumentsText = JSON.stringify({ changes: [{ path: "README.md", content: "after\n" }] })
      response.write(`data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, id: "patch-1", function: { name: "apply_patch", arguments: argumentsText } }] } }] })}\n\n`)
    } else {
      response.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "done" } }] })}\n\n`)
    }
    response.end("data: [DONE]\n\n")
  })
})

provider.listen(0, "127.0.0.1", () => {
  const address = provider.address()
  const baseURL = `http://127.0.0.1:${address.port}/v1/`
  const child = spawn(binary, ["--stdio"], { cwd: root, env: { ...process.env, DEEPSEEK_SESSION_ROOT: sessionRoot }, stdio: ["pipe", "pipe", "pipe"] })
  let buffer = ""
  const frames = []
  child.stdout.setEncoding("utf8")
  child.stdout.on("data", (chunk) => {
    buffer += chunk
    const lines = buffer.split("\n")
    buffer = lines.pop() ?? ""
    for (const line of lines) if (line.trim()) frames.push(JSON.parse(line))
  })
  child.stderr.on("data", (chunk) => process.stderr.write(chunk))
  const common = { sessionID: "turnseq-session", projectPath, baseURL, apiKey: "fixture-key", model: "fixture-model", mode: "accept_edits" }
  child.stdin.write(`${JSON.stringify({ id: "run", method: "session.run", params: { ...common, prompt: "修改 README" } })}\n`)
  const deadline = Date.now() + 10000
  const poll = () => {
    const final = frames.find((frame) => frame.id === "run" && frame.type === "response")
    if (final) {
      try {
        assert.strictEqual(final.ok, true, `session.run did not resolve ok: ${JSON.stringify(final)}`)
        const recorded = frames.filter((frame) => frame.type === "event" && frame.event?.type === "model_stream_recorded").map((frame) => frame.event.turnSequence)
        assert(recorded.length >= 2, `expected at least 2 model_stream_recorded events (one per model round-trip), got ${recorded.length}: ${JSON.stringify(recorded)}`)
        assert.deepStrictEqual(recorded, [...recorded].sort((a, b) => a - b), `turnSequence values should be non-decreasing across round-trips: ${JSON.stringify(recorded)}`)
        assert.notStrictEqual(recorded[0], recorded[1], `the two round-trips should not share the same turnSequence (this was the bug — every call recorded 0): ${JSON.stringify(recorded)}`)
        console.log(`Agent runtime turnSequence checks passed (sequence: ${JSON.stringify(recorded)})`)
        child.kill("SIGTERM"); provider.close()
      } catch (error) { child.kill("SIGKILL"); provider.close(); throw error }
      return
    }
    if (Date.now() > deadline) { child.kill("SIGKILL"); provider.close(); throw new Error(`session.run hung — no response within deadline. Frames so far: ${JSON.stringify(frames, null, 2)}`) }
    setTimeout(poll, 50)
  }
  poll()
})
NODE
