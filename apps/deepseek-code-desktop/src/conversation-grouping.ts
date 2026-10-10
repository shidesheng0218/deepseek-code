// Pure grouping logic extracted from main.tsx so it's testable without mounting
// React or touching Tauri's invoke/listen — these functions decide what the user
// actually sees in the conversation timeline and session list.

export type ToolState = "running" | "done" | "failed"
export type Message = { role: "user" | "assistant" | "tool" | "system"; text: string; kind?: string; tool?: string; state?: ToolState }
export type SessionSummary = { sessionId: string; title: string; updatedAt: number; projectPath: string }

/**
 * 将最终 response 帧合并回本轮流式助手消息，避免流式文本和终态文本各渲染一次。
 * 同一轮中如果模型先输出了工具前置文本，再输出最终答案，只保留最后一个流式占位。
 */
export function reconcileFinalAssistantResponse(messages: Message[], text: string): Message[] {
  let lastUserIndex = -1
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index]?.role === "user") {
      lastUserIndex = index
      break
    }
  }
  const streamIndexes = messages.flatMap((message, index) => index > lastUserIndex && message.role === "assistant" && message.kind === "stream" ? [index] : [])

  if (streamIndexes.length > 0) {
    const finalStreamIndex = streamIndexes.at(-1)
    return messages.flatMap((message, index) => {
      if (!streamIndexes.includes(index)) return [message]
      return index === finalStreamIndex ? [{ role: "assistant", text } satisfies Message] : []
    })
  }

  const alreadyRendered = messages.slice(lastUserIndex + 1).some((message) => message.role === "assistant" && message.kind !== "stream" && message.text === text)
  return alreadyRendered ? messages : [...messages, { role: "assistant", text }]
}

/** 追加流式片段；如果终态回答已经先到，丢弃迟到片段，避免再次创建回复。 */
export function appendAssistantStream(messages: Message[], text: string): Message[] {
  let lastUserIndex = -1
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index]?.role === "user") {
      lastUserIndex = index
      break
    }
  }
  const hasFinalAnswer = messages.slice(lastUserIndex + 1).some((message) => message.role === "assistant" && message.kind !== "stream")
  if (hasFinalAnswer) return messages

  const last = messages.at(-1)
  if (last?.role === "assistant" && last.kind === "stream") {
    return [...messages.slice(0, -1), { ...last, text: last.text + text }]
  }
  return [...messages, { role: "assistant", text, kind: "stream" }]
}

export type ConversationItem = { key: string } & (
  | { kind: "message"; message: Message }
  | { kind: "toolGroup"; activities: Message[] }
)

export const TOOL_ACTIVITY_KINDS = new Set(["tool_requested", "tool_started", "tool_completed", "terminal_completed", "ssh_terminal_opened", "ssh_terminal_completed", "ssh_terminal_closed", "ssh_completed"])

/** 连续的工具活动合并为一个可折叠分组，时间线保持干净。 */
export function groupConversation(messages: Message[]): ConversationItem[] {
  const items: ConversationItem[] = []
  let group: Message[] = []
  const flush = () => {
    if (group.length > 0) {
      items.push({ key: `group-${items.length}`, kind: "toolGroup", activities: group })
      group = []
    }
  }
  messages.forEach((message, index) => {
    if (message.role === "tool" && TOOL_ACTIVITY_KINDS.has(message.kind ?? "")) group.push(message)
    else {
      flush()
      items.push({ key: `msg-${index}`, kind: "message", message })
    }
  })
  flush()
  return items
}

export function projectGroupName(projectPath: string): string {
  if (!projectPath) return "未关联项目"
  const parts = projectPath.split("/").filter(Boolean)
  return parts.at(-1) ?? projectPath
}

export function groupSessionsByProject(sessions: SessionSummary[]): { name: string; sessions: SessionSummary[] }[] {
  const groups = new Map<string, SessionSummary[]>()
  for (const session of sessions) {
    const name = projectGroupName(session.projectPath)
    const existing = groups.get(name) ?? []
    existing.push(session)
    groups.set(name, existing)
  }
  return [...groups.entries()].map(([name, grouped]) => ({ name, sessions: grouped }))
}
