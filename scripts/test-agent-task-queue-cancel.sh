#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$root/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
"$root/scripts/build-agent-sidecar.sh" >/dev/null

node - "$binary" "$root" <<'NODE'
// End-to-end test: task.cancel on a queued ticket transitions it to "failed" and
// task.list reflects that -- proving cancelTicketHandler's canTransition-guarded
// state change actually lands in the durable event log, not just the response.
const assert = require("assert")
const http = require("http")
const { spawn } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

const [binary, root] = process.argv.slice(2)
const projectPath = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-taskqueue-cancel-project-"))
const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-taskqueue-cancel-events-"))
fs.writeFileSync(path.join(projectPath, "README.md"), "before\n")

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
    if (Date.now() > deadline) return reject(new Error(`timed out waiting for ${id}`))
    setTimeout(poll, 20)
  }
  poll()
})

;(async () => {
  try {
    // baseURL points nowhere reachable -- doesn't matter, we cancel before it's ever
    // dispatched to the scheduler's queues/drain engine.
    const enqueueResp = await new Promise((resolve, reject) => {
      send("enqueue", "task.enqueue", { prompt: "won't run", projectPath, baseURL: "http://127.0.0.1:1/v1/", apiKey: "k", model: "m" })
      waitFor("enqueue").then(resolve, reject)
    })
    assert.strictEqual(enqueueResp.ok, true, "expected task.enqueue to succeed")
    const ticketID = enqueueResp.result.ticketID

    send("cancel", "task.cancel", { ticketID })
    const cancelResp = await waitFor("cancel")
    assert.strictEqual(cancelResp.ok, true, `expected task.cancel to succeed: ${JSON.stringify(cancelResp)}`)
    assert.strictEqual(cancelResp.result.state, "failed", "expected cancel to transition ticket to failed")

    send("list", "task.list", {})
    const listResp = await waitFor("list")
    const ticket = listResp.result.tickets.find((t) => t.ticketID === ticketID)
    assert.ok(ticket, "expected cancelled ticket to still appear in task.list")
    assert.strictEqual(ticket.state, "failed", `expected task.list to reflect cancelled state, got: ${ticket.state}`)

    console.log("Agent runtime task-queue cancel checks passed")
    child.kill("SIGKILL")
    process.exit(0)
  } catch (error) {
    child.kill("SIGKILL")
    throw error
  }
})()
NODE
