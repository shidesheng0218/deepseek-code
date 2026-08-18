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
const projectPath = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-terminal-project-"))
const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-terminal-events-"))
let call = 0
const tool = (id, command) => ({ choices: [{ delta: { tool_calls: [{ index: 0, id, function: { name: "run_command", arguments: JSON.stringify({ command }) } }] } }] })
const provider = http.createServer((request, response) => {
  let body = ""; request.on("data", (chunk) => { body += chunk }); request.on("end", () => {
    call += 1; response.writeHead(200, { "content-type": "text/event-stream" })
    const payload = call === 1 ? tool("command-1", "export DEEPSEEK_TERMINAL_STATE=kept") : call === 2 ? tool("command-2", "printf \"$DEEPSEEK_TERMINAL_STATE\"") : { choices: [{ delta: { content: "持久终端状态已保留" } }] }
    response.write(`data: ${JSON.stringify(payload)}\n\n`); response.end("data: [DONE]\n\n")
  })
})
provider.listen(0, "127.0.0.1", () => {
  const baseURL = `http://127.0.0.1:${provider.address().port}/v1/`
  const child = spawn(binary, ["--stdio"], { cwd: root, env: { ...process.env, DEEPSEEK_SESSION_ROOT: sessionRoot }, stdio: ["pipe", "pipe", "pipe"] })
  let buffer = ""; const frames = []
  child.stdout.setEncoding("utf8"); child.stdout.on("data", (chunk) => { buffer += chunk; const lines = buffer.split("\n"); buffer = lines.pop() ?? ""; for (const line of lines) if (line.trim()) frames.push(JSON.parse(line)) })
  child.stdin.write(`${JSON.stringify({ id: "terminal-run", method: "session.run", params: { sessionID: "terminal-session", projectPath, prompt: "验证终端状态", baseURL, apiKey: "fixture", model: "fixture", mode: "auto" } })}\n`)
  const deadline = Date.now() + 5000
  const poll = () => {
    const final = frames.find((frame) => frame.id === "terminal-run" && frame.type === "response")
    if (final) {
      try {
        assert.strictEqual(final.ok, true); assert.strictEqual(final.result.text, "持久终端状态已保留")
        assert(final.result.messages.some((message) => message.role === "tool" && message.content.includes("kept")))
        const events = fs.readFileSync(path.join(sessionRoot, "terminal-session.jsonl"), "utf8")
        assert(events.includes("terminal_completed")); console.log("Agent runtime persistent-terminal checks passed")
        child.kill("SIGTERM"); provider.close()
      } catch (error) { child.kill("SIGKILL"); provider.close(); throw error }
      return
    }
    if (Date.now() > deadline) { child.kill("SIGKILL"); provider.close(); throw new Error(JSON.stringify(frames, null, 2)) }
    setTimeout(poll, 20)
  }; poll()
})
NODE
