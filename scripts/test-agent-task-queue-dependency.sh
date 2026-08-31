#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$root/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
"$root/scripts/build-agent-sidecar.sh" >/dev/null

node - "$binary" "$root" <<'NODE'
// End-to-end test: ticket B has blockedBy: [A.ticketID]. B must sit in
// waiting_dependency (never queued/running) until A reaches done, then transition
// to queued and run. This proves selectDependencyResolved/resolveDependencies are
// actually wired into the scheduler, not just unit-tested in isolation.
const assert = require("assert")
const http = require("http")
const { spawn } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

const [binary, root] = process.argv.slice(2)
const projectPath = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-taskqueue-dep-project-"))
const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-taskqueue-dep-events-"))
fs.writeFileSync(path.join(projectPath, "README.md"), "before\n")

// Model call for ticket A is slow (500ms delay) so we have a real window to observe
// B sitting in waiting_dependency before A finishes.
const provider = http.createServer((request, response) => {
  let body = ""
  request.on("data", (chunk) => { body += chunk })
  request.on("end", () => {
    setTimeout(() => {
      response.writeHead(200, { "content-type": "text/event-stream" })
      response.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "done" } }] })}\n\n`)
      response.end("data: [DONE]\n\n")
    }, 500)
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
      send("enqueue-a", "task.enqueue", { prompt: "工单 A", projectPath, baseURL, apiKey: "fixture-key", model: "fixture-model" })
      const a = await waitFor("enqueue-a")
      assert.strictEqual(a.ok, true)
      const ticketA = a.result.ticketID

      send("enqueue-b", "task.enqueue", { prompt: "工单 B，依赖 A", projectPath, baseURL, apiKey: "fixture-key", model: "fixture-model", blockedBy: [ticketA] })
      const b = await waitFor("enqueue-b")
      assert.strictEqual(b.ok, true)
      const ticketB = b.result.ticketID
      // B must start in waiting_dependency, not queued -- this is the whole point
      assert.strictEqual(b.result.state, "waiting_dependency", `expected B to start blocked, got: ${b.result.state}`)

      // Immediately after enqueueing (well before A's 500ms model call finishes),
      // B must still be waiting_dependency -- proves the scheduler didn't just run
      // everything regardless of the dependency.
      send("list-early", "task.list", {})
      const early = await waitFor("list-early")
      const bEarly = early.result.tickets.find((t) => t.ticketID === ticketB)
      assert.strictEqual(bEarly.state, "waiting_dependency", `B should still be blocked shortly after enqueue, got: ${bEarly.state}`)

      // Now wait for both to reach a terminal state
      const deadline = Date.now() + 15000
      let aFinal, bFinal
      while (Date.now() < deadline) {
        const listID = `list-${Date.now()}`
        send(listID, "task.list", {})
        const listResult = await waitFor(listID)
        const ta = listResult.result.tickets.find((t) => t.ticketID === ticketA)
        const tb = listResult.result.tickets.find((t) => t.ticketID === ticketB)
        if (ta && (ta.state === "done" || ta.state === "failed")) aFinal = ta.state
        if (tb && (tb.state === "done" || tb.state === "failed")) bFinal = tb.state
        if (aFinal && bFinal) break
        await new Promise((r) => setTimeout(r, 300))
      }
      assert.strictEqual(aFinal, "done", `expected A to reach done, got: ${aFinal}`)
      assert.strictEqual(bFinal, "done", `expected B to reach done after A, got: ${bFinal}`)
      console.log("Agent runtime task-queue dependency checks passed")
      child.kill("SIGTERM"); provider.close()
    } catch (error) {
      child.kill("SIGKILL"); provider.close()
      throw error
    }
  })()
})
NODE
