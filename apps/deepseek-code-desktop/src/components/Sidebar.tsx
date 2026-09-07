import { groupSessionsByProject, type SessionSummary } from "../conversation-grouping"
import { Icon } from "./Icon"

export type ViewKey = "chat" | "terminal" | "usage"

export function Sidebar({ view, sessions, activeSessionID, onViewChange, onNewSession, onOpenSettings, onOpenSession }: {
  view: ViewKey
  sessions: SessionSummary[]
  activeSessionID: string
  onViewChange: (view: ViewKey) => void
  onNewSession: () => void
  onOpenSettings: () => void
  onOpenSession: (sessionID: string) => void
}) {
  return <aside className="sidebar" data-tauri-drag-region>
    <div className="brand"><span>◆</span><strong>DeepSeek Code</strong></div>
    <button className="new-session" type="button" onClick={onNewSession}><Icon name="plus" />新建任务</button>
    <nav>
      <button className={view === "chat" ? "active" : ""} type="button" onClick={() => onViewChange("chat")}><Icon name="chat" />会话</button>
      <button type="button" onClick={onOpenSettings}><Icon name="settings" />设置</button>
      <button className={view === "terminal" ? "active" : ""} type="button" onClick={() => onViewChange("terminal")}><Icon name="terminal" />终端</button>
      <button className={view === "usage" ? "active" : ""} type="button" onClick={() => onViewChange("usage")}><Icon name="chart" />用量</button>
    </nav>
    <div className="session-list" aria-label="已保存会话">{groupSessionsByProject(sessions.slice(0, 24)).map((group) => <div className="session-group" key={group.name}>
      <p className="session-group-name"><Icon name="folder" />{group.name}</p>
      {group.sessions.map((session) => <button key={session.sessionId} className={session.sessionId === activeSessionID ? "active-session" : ""} type="button" onClick={() => onOpenSession(session.sessionId)} title={session.title}>{session.title}</button>)}
    </div>)}</div>
    <div className="privacy">本地优先 · 凭据保存在 Keychain</div>
  </aside>
}
