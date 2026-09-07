import type { ReactNode } from "react"
import { groupConversation, type Message } from "../conversation-grouping"
import type { Approval } from "../types"
import { ApprovalCard } from "./ApprovalCard"
import { Markdown } from "./Markdown"
import { ToolActivityGroup } from "./ToolActivityGroup"

export type ViewDensity = "summary" | "normal" | "verbose"

function MessageBody({ message }: { message: Message }) {
  if (message.role === "assistant") return <Markdown text={message.text} streaming={message.kind === "stream"} />
  return <div>{message.text}</div>
}

export function Conversation({ messages, approval, busy, home, density, onResolveApproval }: {
  messages: Message[]
  approval: Approval | null
  busy: boolean
  home?: ReactNode
  density: ViewDensity
  onResolveApproval: (decision: "allow" | "deny") => void
}) {
  const items = groupConversation(messages)
  return <section className={messages.length ? "conversation" : "conversation home"} aria-live="polite">
    {!messages.length && home}
    {items.map((item) => {
      if (item.kind === "toolGroup") {
        if (density === "summary") return <div className="tool-group-compact" key={item.key}>工具活动 · {item.activities.length} 步（简洁视图已折叠）</div>
        return <ToolActivityGroup key={item.key} activities={item.activities} defaultOpen={density === "verbose"} />
      }
      const { message } = item
      // 简洁视图只保留结果与需要用户决策的内容；常规提示性系统消息隐藏。
      if (density === "summary" && message.role === "system" && message.kind !== "error" && message.kind !== "approval") return null
      return <article className={`message ${message.role} ${message.kind ?? ""}`} key={item.key}><span className="message-label">{message.role === "user" ? "你" : message.role === "tool" ? "Runtime" : message.role === "system" ? "系统" : "DeepSeek"}</span><MessageBody message={message} /></article>
    })}
    {approval && <ApprovalCard approval={approval} onResolve={onResolveApproval} />}
    {busy && <div className="typing"><i /><i /><i /> 正在工作</div>}
  </section>
}
