#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$root/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
"$root/scripts/build-agent-sidecar.sh" >/dev/null

node - "$binary" "$root" <<'NODE'
// Regression test for the Verifier's keyword-coverage check (runVerifierWorker's
// step 5): when the user's requirement names a specific identifier that the agent's
// diff never touches, a passing test suite alone should not be enough to call it
// "pass" — it should downgrade to "inconclusive" with the untouched identifier named
// in counterEvidence. This drives a real turn (run_command passing a test, then
// apply_patch touching an unrelated file) through the actual runVerifierWorker path.
const assert = require("assert")
const http = require("http")
const { spawn, execFileSync } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

const [binary, root] = process.argv.slice(2)
const projectPath = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-verifier-kw-project-"))
const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-verifier-kw-events-"))
fs.writeFileSync(path.join(projectPath, "README.md"), "before\n")
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
      // Passing test command first, matching the /\b(test|lint|...)\b/i whitelist
      response.write(`data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, id: "cmd-1", function: { name: "run_command", arguments: JSON.stringify({ command: "echo running test" }) } }] } }] })}\n\n`)
    } else if (modelCalls === 2) {
      // Patch touches README.md only — never touches "LoginService", the identifier
      // the requirement explicitly names
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
  const common = { sessionID: "verifier-kw-session", projectPath, baseURL, apiKey: "fixture-key", model: "fixture-model", mode: "auto" }
  // The requirement explicitly names "LoginService" — the diff never touches it.
  child.stdin.write(`${JSON.stringify({ id: "run", method: "session.run", params: { ...common, prompt: "修复 LoginService 的超时问题" } })}\n`)
  const deadline = Date.now() + 15000
  const poll = () => {
    const final = frames.find((frame) => frame.id === "run" && frame.type === "response")
    if (final) {
      try {
        assert.strictEqual(final.ok, true, `session.run did not resolve ok: ${JSON.stringify(final)}`)
        const verdict = frames.find((frame) => frame.type === "event" && frame.event?.type === "verifier_verdict")
        assert(verdict, "expected a verifier_verdict event")
        assert.strictEqual(verdict.event.state, "inconclusive", `expected inconclusive due to low keyword coverage, got: ${JSON.stringify(verdict.event)}`)
        assert(verdict.event.counterEvidence.some((line) => line.includes("loginservice")), `expected counterEvidence to name the untouched identifier: ${JSON.stringify(verdict.event.counterEvidence)}`)
        console.log("Agent runtime verifier keyword-coverage checks passed")
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
