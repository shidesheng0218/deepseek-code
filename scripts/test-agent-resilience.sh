#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$root/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
"$root/scripts/build-agent-sidecar.sh" >/dev/null

node - "$binary" "$root" <<'NODE'
const assert = require("assert")
const { spawn } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

// 这组用例守着 sidecar 的"坏输入不应该杀死进程"契约：一个进程里跑着所有会话，
// 任何一条畸形/环境异常的请求都不能带走它。每条用例之后都发一次 health 确认存活。
const [binary, root] = process.argv.slice(2)
const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-resilience-events-"))
const missingProject = path.join(os.tmpdir(), `deepseek-missing-project-${process.pid}-${Date.now()}`)
const notARepository = fs.mkdtempSync(path.join(os.tmpdir(), "deepseek-not-a-repo-"))

const child = spawn(binary, ["--stdio"], { cwd: root, env: { ...process.env, DEEPSEEK_SESSION_ROOT: sessionRoot }, stdio: ["pipe", "pipe", "pipe"] })
let buffer = ""
let stderr = ""
let exited = false
const frames = []

child.stdout.setEncoding("utf8")
child.stdout.on("data", (chunk) => {
  buffer += chunk
  const lines = buffer.split("\n")
  buffer = lines.pop() ?? ""
  for (const line of lines) if (line.trim()) frames.push(JSON.parse(line))
})
child.stderr.setEncoding("utf8")
child.stderr.on("data", (chunk) => { stderr += chunk })
child.on("exit", () => { exited = true })

const send = (payload) => child.stdin.write(`${JSON.stringify(payload)}\n`)

async function waitFor(id, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const frame = frames.find((candidate) => candidate.id === id && candidate.type === "response")
    if (frame) return frame
    if (exited) throw new Error(`sidecar exited while waiting for "${id}" — stderr: ${stderr}`)
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  throw new Error(`timed out waiting for "${id}" — frames: ${JSON.stringify(frames)} — stderr: ${stderr}`)
}

async function assertAlive(label) {
  const id = `health-${label}`
  send({ id, method: "health" })
  const frame = await waitFor(id)
  assert.strictEqual(frame.ok, true, `sidecar must still answer health after ${label}`)
}

async function main() {
  // 1. terminal.open 指向不存在的目录：以前是 spawn 的 ENOENT 变成未捕获异常，
  //    整个进程连同所有会话一起退出。
  send({ id: "bad-terminal", method: "terminal.open", params: { sessionID: "resilience", projectPath: missingProject } })
  const terminal = await waitFor("bad-terminal")
  assert.strictEqual(terminal.ok, false, "terminal.open with a missing project path must return an error response")
  assert.match(String(terminal.error), /unavailable|directory/i, `unexpected terminal error: ${terminal.error}`)
  await assertAlive("terminal.open failure")

  // 2. 畸形 JSON 行：回一条错误响应，进程继续服务。
  child.stdin.write("this is not json\n")
  const invalid = await waitFor("unknown")
  assert.strictEqual(invalid.ok, false, "invalid JSON must produce an error response")
  await assertAlive("invalid JSON")

  // 3. session.arena 用非 git 目录：worktree 建不起来。以前这个 reject 无人接住，
  //    进程直接退出、调用方永远收不到响应。
  send({
    id: "bad-arena",
    method: "session.arena",
    params: { sessionID: "resilience", projectPath: notARepository, prompt: "验证竞技场失败路径", baseURL: "http://127.0.0.1:1/v1", apiKey: "fixture", model: "fixture", mode: "auto" }
  })
  const arena = await waitFor("bad-arena", 30000)
  assert.strictEqual(arena.ok, false, "session.arena on a non-git directory must return an error response")
  assert.match(String(arena.error), /worktree/i, `unexpected arena error: ${arena.error}`)
  await assertAlive("session.arena failure")

  console.log("Agent runtime resilience checks passed")
}

main()
  .then(() => { child.kill("SIGTERM"); process.exit(0) })
  .catch((error) => {
    child.kill("SIGKILL")
    console.error(error && error.stack ? error.stack : String(error))
    process.exit(1)
  })
NODE