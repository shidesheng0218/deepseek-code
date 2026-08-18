#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$root/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
"$root/scripts/build-agent-sidecar.sh" >/dev/null

node - "$binary" "$root" <<'NODE'
const assert = require("assert")
const http = require("http")
const { spawn } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

const [binary, root] = process.argv.slice(2)
const projectPath = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-approval-project-"))
const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-approval-events-"))
fs.writeFileSync(path.join(projectPath, "README.md"), "before\n")
let modelCalls = 0
const provider = http.createServer((request, response) => {
  let body = ""
  request.on("data", (chunk) => { body += chunk })
  request.on("end", () => {
    modelCalls += 1
    const parsed = JSON.parse(body)
    response.writeHead(200, { "content-type": "text/event-stream" })
    if (modelCalls === 1) {
      const argumentsText = JSON.stringify({ changes: [{ path: "README.md", content: "after\n" }] })
      response.write(`data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, id: "patch-1", function: { name: "apply_patch", arguments: argumentsText } }] } }] })}\n\n`)
    } else {
      assert(parsed.messages.some((message) => message.role === "tool" && message.tool_call_id === "patch-1"))
      response.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "已完成经过批准的修改" } }] })}\n\n`)
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
  const common = { sessionID: "approval-session", projectPath, baseURL, apiKey: "fixture-key", model: "fixture-model", mode: "manual" }
  child.stdin.write(`${JSON.stringify({ id: "run", method: "session.run", params: { ...common, prompt: "修改 README" } })}\n`)
  const deadline = Date.now() + 5000
  let resolved = false
  const poll = () => {
    const approval = frames.find((frame) => frame.type === "event" && frame.event?.type === "approval_required")
    if (approval && !resolved) {
      resolved = true
      child.stdin.write(`${JSON.stringify({ id: "resolve", method: "session.resolveApproval", params: { ...common, approvalID: approval.event.id, decision: "allow" } })}\n`)
    }
    const final = frames.find((frame) => frame.id === "resolve" && frame.type === "response")
    if (final) {
      try {
        assert.strictEqual(final.ok, true)
        assert.strictEqual(final.result.text, "已完成经过批准的修改")
        assert.strictEqual(fs.readFileSync(path.join(projectPath, "README.md"), "utf8"), "after\n")
        assert(frames.some((frame) => frame.type === "event" && frame.event?.type === "tool_completed"))
        console.log("Agent runtime approval-resume checks passed")
        child.kill("SIGTERM"); provider.close()
      } catch (error) { child.kill("SIGKILL"); provider.close(); throw error }
      return
    }
    if (Date.now() > deadline) { child.kill("SIGKILL"); provider.close(); throw new Error(JSON.stringify(frames, null, 2)) }
    setTimeout(poll, 20)
  }
  poll()
})
NODE
