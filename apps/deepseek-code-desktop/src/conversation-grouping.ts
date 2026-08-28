// Pure grouping logic extracted from main.tsx so it's testable without mounting
// React or touching Tauri's invoke/listen — these functions decide what the user
// actually sees in the conversation timeline and session list.

export type Message = { role: "user" | "assistant" | "tool" | "system"; text: string; kind?: string }
export type SessionSummary = { sessionId: string; title: string; updatedAt: number; projectPath: string }

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
