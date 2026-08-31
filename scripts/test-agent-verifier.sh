#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$root/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
"$root/scripts/build-agent-sidecar.sh" >/dev/null

node - "$binary" "$root" <<'NODE'
// Regression test for a real hang bug: execFile("git", [...apply...], { input: diff })
// silently ignores the `input` option (only execFileSync/spawnSync support it), so
// `git apply` sat waiting on a stdin that was never written to or closed. Every turn
// where the agent successfully applied a patch triggered runVerifierWorker(), which
// hit this exact line and hung forever — session.run never resolved, no response ever
// reached the caller. This test drives a full turn with mode:"accept_edits" so the
// patch actually applies without a human approval round-trip, which is what makes
// runVerifierWorker's hasModification check true and triggers the Verifier path.
const assert = require("assert")
const http = require("http")
const { spawn } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")
const { execFileSync } = require("child_process")

const [binary, root] = process.argv.slice(2)
const projectPath = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-verifier-project-"))
const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-verifier-events-"))
fs.writeFileSync(path.join(projectPath, "README.md"), "before\n")
// runVerifierWorker creates a real git worktree off HEAD, so the fixture needs a
// real git repo with at least one commit — not just a directory.
execFileSync("git", ["init", "-q"], { cwd: projectPath })
execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectPath })
execFileSync("git", ["config", "user.name", "Test"], { cwd: projectPath })
execFileSync("git", ["add", "README.md"], { cwd: projectPath })
execFileSync("git", ["commit", "-q", "-m", "initial"], { cwd: projectPath })

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
      response.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "已完成修改" } }] })}\n\n`)
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
  const common = { sessionID: "verifier-session", projectPath, baseURL, apiKey: "fixture-key", model: "fixture-model", mode: "accept_edits" }
  child.stdin.write(`${JSON.stringify({ id: "run", method: "session.run", params: { ...common, prompt: "修改 README" } })}\n`)
  // 10s deadline is generous: before the fix this would hang forever (never resolve),
  // so any finite deadline firing before the response arrives proves the hang is real.
  const deadline = Date.now() + 10000
  const poll = () => {
    const final = frames.find((frame) => frame.id === "run" && frame.type === "response")
    if (final) {
      try {
        assert.strictEqual(final.ok, true, `session.run did not resolve ok: ${JSON.stringify(final)}`)
        assert.strictEqual(fs.readFileSync(path.join(projectPath, "README.md"), "utf8"), "after\n")
        const verdict = frames.find((frame) => frame.type === "event" && frame.event?.type === "verifier_verdict")
        assert(verdict, "expected a verifier_verdict event — runVerifierWorker never completed")
        assert(["pass", "refuted", "inconclusive"].includes(verdict.event.state), `unexpected verifier state: ${verdict.event.state}`)
        console.log(`Agent runtime verifier checks passed (verdict: ${verdict.event.state})`)
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
