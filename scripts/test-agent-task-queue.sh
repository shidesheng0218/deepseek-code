#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$root/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
"$root/scripts/build-agent-sidecar.sh" >/dev/null

node - "$binary" "$root" <<'NODE'
// End-to-end test for the task queue (src/core/task-queue.ts + main.ts wiring):
// task.enqueue creates a ticket, the scheduler tick picks it up and runs it through
// the real executeRun path, and task.list reflects it reaching "done".
const assert = require("assert")
const http = require("http")
const { spawn } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

const [binary, root] = process.argv.slice(2)
const projectPath = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-taskqueue-project-"))
const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-taskqueue-events-"))
fs.writeFileSync(path.join(projectPath, "README.md"), "before\n")

const provider = http.createServer((request, response) => {
  let body = ""
  request.on("data", (chunk) => { body += chunk })
  request.on("end", () => {
    response.writeHead(200, { "content-type": "text/event-stream" })
    response.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "工单完成" } }] })}\n\n`)
    response.end("data: [DONE]\n\n")
  })
})

provider.listen(0, "127.0.0.1", () => {
  const address = provider.address()
  const baseURL = `http://127.0.0.1:${address.port}/v1/`
  const child = spawn(binary, ["--stdio"], { cwd: root, env: { ...process.env, DEEPSEEK_SESSION_ROOT: sessionRoot }, stdio: ["pipe", "pipe", "pipe"] })
  let buffer = ""
  const responses = new Map()
  child.stdout.setEncoding("utf8")
  child.stdout.on("data", (chunk) => {
    buffer += chunk
    const lines = buffer.split("\n")
    buffer = lines.pop() ?? ""
    for (const line of lines) {
      if (!line.trim()) continue
      const frame = JSON.parse(line)
      if (frame.type === "response") responses.set(frame.id, frame)
    }
  })
  child.stderr.on("data", (chunk) => process.stderr.write(chunk))

  const send = (id, method, params) => child.stdin.write(`${JSON.stringify({ id, method, params })}\n`)
  const waitFor = (id, timeoutMs = 8000) => new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs
    const poll = () => {
      if (responses.has(id)) return resolve(responses.get(id))
      if (Date.now() > deadline) return reject(new Error(`timed out waiting for response ${id}`))
      setTimeout(poll, 50)
    }
    poll()
  })

  ;(async () => {
    try {
      send("enqueue-1", "task.enqueue", { prompt: "跑一个简单工单", projectPath, baseURL, apiKey: "fixture-key", model: "fixture-model" })
      const enqueueResult = await waitFor("enqueue-1")
      assert.strictEqual(enqueueResult.ok, true, `task.enqueue failed: ${JSON.stringify(enqueueResult)}`)
      const ticketID = enqueueResult.result.ticketID
      assert.strictEqual(enqueueResult.result.state, "queued")

      // Poll task.list until the scheduler (30s interval, but enqueueTicket also
      // fires an immediate tick) picks it up and runs it to completion.
      const deadline = Date.now() + 15000
      let finalState
      while (Date.now() < deadline) {
        const listID = `list-${Date.now()}`
        send(listID, "task.list", {})
        const listResult = await waitFor(listID)
        const ticket = listResult.result.tickets.find((t) => t.ticketID === ticketID)
        assert(ticket, `ticket ${ticketID} disappeared from task.list`)
        if (ticket.state === "done" || ticket.state === "failed") { finalState = ticket.state; break }
        await new Promise((r) => setTimeout(r, 300))
      }
      assert.strictEqual(finalState, "done", `expected ticket to reach done, got: ${finalState}`)
      console.log("Agent runtime task-queue lifecycle checks passed")
      child.kill("SIGTERM"); provider.close()
    } catch (error) {
      child.kill("SIGKILL"); provider.close()
      throw error
    }
  })()
})
NODE
