#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bun="$root/node_modules/@oven/bun-darwin-aarch64/bin/bun"
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
const projectPath = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-agent-runtime-"))
const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-agent-events-"))

const providerRequests = []
const provider = http.createServer((request, response) => {
  let body = ""
  request.on("data", (chunk) => { body += chunk })
  request.on("end", () => {
    const parsed = JSON.parse(body)
    providerRequests.push(parsed)
    assert.strictEqual(parsed.model, "fixture-model")
    assert.strictEqual(parsed.stream, true)
    assert(parsed.tools.some((tool) => tool.function.name === "web_search"))
    assert(parsed.tools.some((tool) => tool.function.name === "web_fetch"))
    response.writeHead(200, { "content-type": "text/event-stream" })
    const text = providerRequests.length === 1 ? "第一轮 Provider 回复" : "第二轮 Provider 回复"
    response.write(`data: ${JSON.stringify({ choices: [{ delta: { content: text } }] })}\n\n`)
    response.end("data: [DONE]\n\n")
  })
})

provider.listen(0, "127.0.0.1", () => {
  const address = provider.address()
  const baseURL = `http://127.0.0.1:${address.port}/v1/`
  const child = spawn(binary, ["--stdio"], {
    cwd: root,
    env: { ...process.env, DEEPSEEK_SESSION_ROOT: sessionRoot },
    stdio: ["pipe", "pipe", "pipe"]
  })
  let buffer = ""
  const messages = []
  child.stdout.setEncoding("utf8")
  child.stdout.on("data", (chunk) => {
    buffer += chunk
    const lines = buffer.split("\n")
    buffer = lines.pop() ?? ""
    for (const line of lines) {
      if (line.trim()) messages.push(JSON.parse(line))
    }
  })
  child.stderr.on("data", (chunk) => process.stderr.write(chunk))

  const request = (id, prompt) => ({
    id,
    method: "session.run",
    params: {
      sessionID: "fixture-session",
      projectPath,
      prompt,
      baseURL,
      apiKey: "fixture-key",
      model: "fixture-model",
      mode: "plan"
    }
  })
  child.stdin.write(`${JSON.stringify(request("fixture-run-1", "第一轮问题"))}\n`)

  const deadline = Date.now() + 5000
  let secondSent = false
  const poll = () => {
    const first = messages.find((message) => message.id === "fixture-run-1" && message.type === "response")
    if (first && !secondSent) {
      secondSent = true
      child.stdin.write(`${JSON.stringify(request("fixture-run-2", "第二轮问题"))}\n`)
    }
    const final = messages.find((message) => message.id === "fixture-run-2" && message.type === "response")
    if (final) {
      try {
        assert.strictEqual(final.ok, true)
        assert.strictEqual(first.result.text, "第一轮 Provider 回复")
        assert.strictEqual(final.result.text, "第二轮 Provider 回复")
        assert.strictEqual(providerRequests[1].messages[0].role, "system")
        assert.deepStrictEqual(providerRequests[1].messages.slice(1).map((message) => ({ role: message.role, content: message.content })), [
          { role: "user", content: "第一轮问题" },
          { role: "assistant", content: "第一轮 Provider 回复" },
          { role: "user", content: "第二轮问题" }
        ])
        assert(messages.some((message) => message.type === "event" && message.event.type === "turn_started"))
        assert(messages.some((message) => message.type === "event" && message.event.type === "assistant_text"))
        assert(messages.some((message) => message.type === "event" && message.event.type === "turn_ended"))
        const eventFile = path.join(sessionRoot, "fixture-session.jsonl")
        assert(fs.existsSync(eventFile))
        console.log("Agent runtime Provider/SSE checks passed")
        child.kill("SIGTERM")
        provider.close()
      } catch (error) {
        console.error(JSON.stringify(messages, null, 2))
        child.kill("SIGKILL")
        provider.close()
        process.exitCode = 1
        throw error
      }
      return
    }
    if (Date.now() > deadline) {
      child.kill("SIGKILL")
      provider.close()
      throw new Error(`Timed out waiting for runtime response: ${JSON.stringify(messages)}`)
    }
    setTimeout(poll, 20)
  }
  poll()
})
NODE
