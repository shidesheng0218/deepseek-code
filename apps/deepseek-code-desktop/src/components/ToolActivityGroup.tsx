import type { Message } from "../conversation-grouping"
import { Icon } from "./Icon"

function activityState(activity: Message): "running" | "done" | "failed" {
  if (activity.state) return activity.state
  if (activity.kind === "tool_requested" || activity.kind === "tool_started") return "running"
  if (/失败|错误|退出码 [1-9]|结果未知/.test(activity.text)) return "failed"
  return "done"
}

function StateDot({ state }: { state: "running" | "done" | "failed" }) {
  if (state === "running") return <i className="tool-dot running" aria-label="进行中" />
  if (state === "failed") return <i className="tool-dot failed" aria-label="失败" />
  return <i className="tool-dot done" aria-label="完成" />
}

export function ToolActivityGroup({ activities, defaultOpen }: { activities: Message[]; defaultOpen?: boolean }) {
  const failed = activities.filter((activity) => activityState(activity) === "failed").length
  const running = activityState(activities[activities.length - 1]) === "running"
  const latest = activities[activities.length - 1]?.text ?? ""
  return <details className="tool-group" open={defaultOpen || undefined}>
    <summary>
      <span className="tool-group-title">
        {running ? <i className="tool-dot running" /> : <Icon name={failed > 0 ? "x" : "check"} />}
        工具活动 · {activities.length} 步{failed > 0 ? ` · ${failed} 个失败` : ""}{running ? " · 进行中" : ""}
      </span>
      <span className="tool-group-latest">{latest}</span>
    </summary>
    <div className="tool-group-items">{activities.map((activity, index) => <div className="tool-group-item" key={index}><StateDot state={activityState(activity)} /><span>{activity.text}</span></div>)}</div>
  </details>
}
