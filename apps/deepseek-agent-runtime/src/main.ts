import { appendFile, mkdir, readFile } from "node:fs/promises"
import { dirname, join } from "node:path"
import { AgentExecutor, type AgentExecutorEvent, type AgentMessage, type ApprovedToolCall } from "../../../src/core/agent-executor"
import { OpenAICompatibleClient, type ModelEvent } from "../../../src/core/providers/openai-compatible"
import { createWorkspaceAgentTools } from "../../../src/core/tools/agent-tools"
import { createWebTools } from "../../../src/core/tools/web"
import type { AgentMode } from "../../../src/core/permissions"

type Request = {
  id: string
  method: "health" | "session.enqueue" | "session.run" | "session.resolveApproval"
  params?: {
    sessionID?: string
    projectPath?: string
    prompt?: string
    baseURL?: string
    apiKey?: string
    model?: string
    mode?: AgentMode
    approvalID?: string
    decision?: "allow" | "deny"
  }
}

type Response = { id: string; type: "response"; ok: boolean; result?: unknown; error?: string }
type RuntimeEventFrame = {
  id: string
  type: "event"
  ok: true
  sessionID: string
  event: RuntimeEvent
}
type OutputFrame = Response | RuntimeEventFrame
type RunRequest = { id: string; params: Required<NonNullable<Request["params"]>> }
type RuntimeEvent =
  | AgentExecutorEvent
  | { type: "turn_started"; prompt: string }
  | { type: "turn_ended"; reason: string; status?: string; error?: string }
  | { type: "usage_recorded"; inputTokens?: number; outputTokens?: number }
type PendingApproval = ApprovedToolCall & { approvalID: string; risk: string }

const toolSchemas = [
  { type: "function", function: { name: "list_directory", description: "列出工作区目录", parameters: { type: "object", properties: { path: { type: "string" } }, required: [] } } },
  { type: "function", function: { name: "search_workspace", description: "在工作区搜索文本", parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } } },
  { type: "function", function: { name: "read_file", description: "读取工作区文件", parameters: { type: "object", properties: { path: { type: "string" }, startLine: { type: "number" }, maxLines: { type: "number" } }, required: ["path"] } } },
  { type: "function", function: { name: "apply_patch", description: "以检查点和哈希校验为前提修改文件", parameters: { type: "object", properties: { label: { type: "string" }, changes: { type: "array", items: { type: "object", properties: { path: { type: "string" }, content: { type: "string" }, expectedHash: { type: "string" } }, required: ["path", "content"] } } }, required: ["changes"] } } },
  { type: "function", function: { name: "inspect_git", description: "查看 Git 状态", parameters: { type: "object", properties: {}, required: [] } } },
  { type: "function", function: { name: "run_command", description: "在工作区目录运行命令", parameters: { type: "object", properties: { command: { type: "string" }, timeoutMs: { type: "number" } }, required: ["command"] } } },
  { type: "function", function: { name: "web_search", description: "搜索公开网页资料，最多返回 8 条来源", parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } } },
  { type: "function", function: { name: "web_fetch", description: "抓取公开 HTTP/HTTPS 页面并返回清洗内容、来源和内容哈希", parameters: { type: "object", properties: { url: { type: "string" } }, required: ["url"] } } }
]

function redact(value: string): string {
  return value
    .replace(/sk-[A-Za-z0-9_-]{8,}/g, "[REDACTED_KEY]")
    .replace(/(Bearer\s+)[^\s]+/gi, "$1[REDACTED]")
}

function sessionRoot(): string {
  return process.env.DEEPSEEK_SESSION_ROOT ?? join(process.env.HOME ?? ".", "Library", "Application Support", "DeepSeekCode", "sessions")
}

class JsonlEventStore {
  private readonly sequences = new Map<string, number>()
  private readonly tails = new Map<string, Promise<void>>()

  async append(sessionID: string, type: string, payload: Record<string, unknown>): Promise<void> {
    const previous = this.tails.get(sessionID) ?? Promise.resolve()
    const next = previous.then(async () => {
      const directory = sessionRoot()
      const file = join(directory, `${sessionID}.jsonl`)
      await mkdir(dirname(file), { recursive: true })
      let sequence = this.sequences.get(sessionID)
      if (sequence === undefined) {
        try {
          const existing = await readFile(file, "utf8")
          sequence = existing.split("\n").filter(Boolean).length
        } catch {
          sequence = 0
        }
      }
      sequence += 1
      this.sequences.set(sessionID, sequence)
      await appendFile(file, `${JSON.stringify({ eventID: crypto.randomUUID(), sessionID, sequence, type, payload, createdAt: new Date().toISOString() })}\n`)
    })
    this.tails.set(sessionID, next.catch(() => undefined))
    await next
  }

  async flush(sessionID: string): Promise<void> {
    await this.tails.get(sessionID)
  }

  async loadConversation(sessionID: string): Promise<AgentMessage[]> {
    const file = join(sessionRoot(), `${sessionID}.jsonl`)
    let entries: Array<{ type?: string; payload?: Record<string, unknown> }> = []
    try {
      entries = (await readFile(file, "utf8")).split("\n").filter(Boolean).flatMap((line) => {
        try { return [JSON.parse(line) as { type?: string; payload?: Record<string, unknown> }] } catch { return [] }
      })
    } catch { return [] }
    const messages: AgentMessage[] = []
    let assistant = ""
    for (const entry of entries) {
      if (entry.type === "turn_started" && typeof entry.payload?.prompt === "string") messages.push({ role: "user", content: entry.payload.prompt })
      if (entry.type === "assistant_text" && typeof entry.payload?.text === "string") assistant += entry.payload.text
      if (entry.type === "turn_ended") {
        if (assistant) messages.push({ role: "assistant", content: assistant })
        assistant = ""
      }
    }
    return messages.slice(-24)
  }

  async loadPendingApproval(sessionID: string, approvalID: string): Promise<PendingApproval | undefined> {
    const file = join(sessionRoot(), `${sessionID}.jsonl`)
    try {
      const entries = (await readFile(file, "utf8")).split("\n").filter(Boolean).flatMap((line) => {
        try { return [JSON.parse(line) as { type?: string; payload?: Record<string, unknown> }] } catch { return [] }
      })
      for (const entry of entries.reverse()) {
        if (entry.payload?.approvalID !== approvalID) continue
        if (entry.type === "approval_resolved") return undefined
        if (entry.type !== "approval_pending") continue
        const tool = entry.payload.tool
        const argumentsValue = entry.payload.arguments
        const risk = entry.payload.risk
        if (typeof tool === "string" && argumentsValue && typeof argumentsValue === "object" && typeof risk === "string") {
          return { approvalID, id: approvalID, tool, arguments: argumentsValue as Record<string, unknown>, risk }
        }
      }
    } catch { /* A missing event log means there is no recoverable approval. */ }
    return undefined
  }
}

const eventStore = new JsonlEventStore()
const queues = new Map<string, RunRequest[]>()
const activeSessions = new Set<string>()

function respond(response: OutputFrame): void {
  process.stdout.write(`${JSON.stringify(response)}\n`)
}

async function emitSessionEvent(sessionID: string, event: RuntimeEvent): Promise<void> {
  const redacted = redactPayload(event)
  await eventStore.append(sessionID, event.type, redacted)
  respond({ id: `${sessionID}:${Date.now()}:${Math.random()}`, type: "event", ok: true, sessionID, event: redacted as RuntimeEvent })
}

async function emitAgentEvent(sessionID: string, event: AgentExecutorEvent): Promise<void> {
  await emitSessionEvent(sessionID, event)
}

function redactUnknown(value: unknown): unknown {
  if (typeof value === "string") return redact(value)
  if (Array.isArray(value)) return value.map(redactUnknown)
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([key, child]) => [key, redactUnknown(child)]))
  return value
}

function redactPayload(event: AgentExecutorEvent | RuntimeEvent): Record<string, unknown> {
  return redactUnknown(event) as Record<string, unknown>
}

function streamModel(sessionID: string, client: OpenAICompatibleClient, model: string, messages: AgentMessage[]): AsyncIterable<Extract<ModelEvent, { type: "text_delta" | "tool_call" }>> {
  return (async function* () {
    for await (const event of client.stream({ model, messages, feature: "main_agent", tools: toolSchemas })) {
      if (event.type === "text_delta" || event.type === "tool_call") yield event
      if (event.type === "usage") {
        await emitSessionEvent(sessionID, {
          type: "usage_recorded",
          inputTokens: event.inputTokens,
          outputTokens: event.outputTokens
        })
      }
    }
  })()
}

async function executeRun(request: RunRequest): Promise<{ text: string; status: string; messages: AgentMessage[] }> {
  const params = request.params
  const sessionID = params.sessionID
  const projectPath = params.projectPath
  const prompt = params.prompt.trim()
  if (!params.baseURL || !params.apiKey || !params.model || !projectPath || !prompt) throw new Error("session.run requires projectPath, prompt, baseURL, apiKey and model")
  const client = new OpenAICompatibleClient({ baseUrl: params.baseURL, apiKey: params.apiKey })
  const tools = createWorkspaceAgentTools({ root: projectPath, checkpointRoot: join(sessionRoot(), "checkpoints", sessionID) })
  const webTools = createWebTools()
  const history = await eventStore.loadConversation(sessionID)
  await emitSessionEvent(sessionID, { type: "turn_started", prompt })
  const executor = new AgentExecutor({
    mode: params.mode ?? "accept_edits",
    model: { stream: (messages) => streamModel(sessionID, client, params.model, messages) },
    tools: {
      list_directory: tools.list_directory,
      search_workspace: tools.search_workspace,
      read_file: tools.read_file,
      apply_patch: tools.apply_patch,
      inspect_git: tools.inspect_git,
      run_command: tools.run_command,
      web_search: webTools.web_search,
      web_fetch: webTools.web_fetch
    },
    onEvent: (event) => { void emitAgentEvent(sessionID, event) }
  })
  try {
    const result = await executor.run(sessionID, prompt, history)
    await eventStore.flush(sessionID)
    if (result.pendingApproval) {
      await eventStore.append(sessionID, "approval_pending", redactUnknown({
        approvalID: result.pendingApproval.id,
        tool: result.pendingApproval.tool,
        arguments: result.pendingApproval.arguments,
        risk: result.pendingApproval.risk
      }) as Record<string, unknown>)
    }
    await emitSessionEvent(sessionID, {
      type: "turn_ended",
      reason: result.status === "waiting_approval" ? "awaiting_approval" : "completed",
      status: result.status
    })
    return { text: redact(result.text), status: result.status, messages: result.messages }
  } catch (error) {
    const message = redact(error instanceof Error ? error.message : String(error))
    await emitSessionEvent(sessionID, { type: "turn_ended", reason: "error", error: message })
    throw new Error(message)
  }
}

async function executeApproval(request: Request): Promise<{ text: string; status: string; messages: AgentMessage[] }> {
  const params = request.params
  const sessionID = params?.sessionID?.trim()
  const approvalID = params?.approvalID?.trim()
  if (!sessionID || !approvalID || !params?.decision || !params.projectPath || !params.baseURL || !params.apiKey || !params.model) throw new Error("session.resolveApproval requires sessionID, approvalID, decision, projectPath, baseURL, apiKey and model")
  const pending = await eventStore.loadPendingApproval(sessionID, approvalID)
  if (!pending) throw new Error("Approval continuation was not found or has already been resolved")
  await eventStore.append(sessionID, "approval_resolved", { approvalID, decision: params.decision })
  if (params.decision === "deny") {
    await emitSessionEvent(sessionID, { type: "turn_ended", reason: "approval_denied", status: "cancelled" })
    return { text: "已取消该操作。", status: "cancelled", messages: await eventStore.loadConversation(sessionID) }
  }
  const client = new OpenAICompatibleClient({ baseUrl: params.baseURL, apiKey: params.apiKey })
  const tools = createWorkspaceAgentTools({ root: params.projectPath, checkpointRoot: join(sessionRoot(), "checkpoints", sessionID) })
  const webTools = createWebTools()
  const executor = new AgentExecutor({
    mode: params.mode ?? "accept_edits",
    model: { stream: (messages) => streamModel(sessionID, client, params.model!, messages) },
    tools: { list_directory: tools.list_directory, search_workspace: tools.search_workspace, read_file: tools.read_file, apply_patch: tools.apply_patch, inspect_git: tools.inspect_git, run_command: tools.run_command, web_search: webTools.web_search, web_fetch: webTools.web_fetch },
    onEvent: (event) => { void emitAgentEvent(sessionID, event) }
  })
  const result = await executor.resume(sessionID, await eventStore.loadConversation(sessionID), pending)
  await eventStore.flush(sessionID)
  await emitSessionEvent(sessionID, { type: "turn_ended", reason: "completed", status: result.status })
  return { text: redact(result.text), status: result.status, messages: result.messages }
}

async function drain(sessionID: string): Promise<void> {
  if (activeSessions.has(sessionID)) return
  activeSessions.add(sessionID)
  try {
    const queue = queues.get(sessionID) ?? []
    while (queue.length > 0) {
      const request = queue.shift()!
      try {
        respond({ id: request.id, type: "response", ok: true, result: await executeRun(request) })
      } catch (error) {
        respond({ id: request.id, type: "response", ok: false, error: redact(error instanceof Error ? error.message : String(error)) })
      }
    }
  } finally {
    activeSessions.delete(sessionID)
    if ((queues.get(sessionID)?.length ?? 0) > 0) void drain(sessionID)
  }
}

function enqueue(request: Request): Response {
  const params = request.params
  const sessionID = params?.sessionID?.trim()
  const text = params?.prompt?.trim() || params?.text?.trim()
  if (!sessionID || !text) return { id: request.id, type: "response", ok: false, error: "sessionID and text are required" }
  const queue = queues.get(sessionID) ?? []
  queue.push({ id: request.id, params: { ...params, sessionID, prompt: text } as RunRequest["params"] })
  queues.set(sessionID, queue)
  void drain(sessionID)
  return { id: request.id, type: "response", ok: true, result: { queued: queue.length, sessionID } }
}

async function handle(request: Request): Promise<void> {
  if (request.method === "health") {
    respond({ id: request.id, type: "response", ok: true, result: { version: "deepseek-agent-runtime/0.2.0" } })
    return
  }
  if (request.method === "session.enqueue") {
    respond(enqueue(request))
    return
  }
  if (request.method === "session.resolveApproval") {
    try { respond({ id: request.id, type: "response", ok: true, result: await executeApproval(request) }) }
    catch (error) { respond({ id: request.id, type: "response", ok: false, error: redact(error instanceof Error ? error.message : String(error)) }) }
    return
  }
  // A run request receives exactly one terminal response after the turn;
  // queued runs never emit a misleading immediate success response.
  enqueue(request)
}

if (process.argv[2] === "health") {
  process.stdout.write("deepseek-agent-runtime/0.2.0\n")
  process.exit(0)
}

let buffer = ""
process.stdin.setEncoding("utf8")
process.stdin.on("data", (chunk: string) => {
  buffer += chunk
  const lines = buffer.split("\n")
  buffer = lines.pop() ?? ""
  for (const line of lines) {
    if (!line.trim()) continue
    try { void handle(JSON.parse(line) as Request) }
    catch { respond({ id: "unknown", type: "response", ok: false, error: "invalid JSON request" }) }
  }
})
