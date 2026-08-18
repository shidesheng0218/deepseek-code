type Request = { id: string; method: "health" | "session.enqueue"; params?: { sessionID?: string; text?: string } }
type Response = { id: string; ok: boolean; result?: unknown; error?: string }

const queues = new Map<string, string[]>()

function respond(response: Response) { process.stdout.write(`${JSON.stringify(response)}\n`) }

function handle(request: Request): Response {
  if (request.method === "health") return { id: request.id, ok: true, result: { version: "deepseek-agent-runtime/0.1.0" } }
  const sessionID = request.params?.sessionID?.trim()
  const text = request.params?.text?.trim()
  if (!sessionID || !text) return { id: request.id, ok: false, error: "sessionID and text are required" }
  const queue = queues.get(sessionID) ?? []
  queue.push(text)
  queues.set(sessionID, queue)
  return { id: request.id, ok: true, result: { queued: queue.length } }
}

if (process.argv[2] === "health") { process.stdout.write("deepseek-agent-runtime/0.1.0\n"); process.exit(0) }

let buffer = ""
process.stdin.setEncoding("utf8")
process.stdin.on("data", (chunk: string) => {
  buffer += chunk
  const lines = buffer.split("\n")
  buffer = lines.pop() ?? ""
  for (const line of lines) {
    if (!line.trim()) continue
    try { respond(handle(JSON.parse(line) as Request)) }
    catch { respond({ id: "unknown", ok: false, error: "invalid JSON request" }) }
  }
})
