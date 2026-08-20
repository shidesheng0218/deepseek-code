import { invoke } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { useEffect, useMemo, useRef, useState } from "react"
import { createRoot } from "react-dom/client"
import "./styles.css"
import { canSubmitTask, shouldRenderFrame, submitActionLabel } from "./interaction-policy"

type RuntimeStatus = { ready: boolean; version: string; detail?: string }
type Settings = { baseUrl: string; model: string; fastModel?: string; projectPath: string; apiKey: string; protocol: "openai-compatible" | "anthropic-messages" }
type SessionSummary = { sessionId: string; title: string; updatedAt: number; projectPath: string }
type UsageStats = { sessions: number; messages: number; totalTokens: number; inputTokens: number; outputTokens: number; cachedTokens: number; activeDays: number; currentStreak: number; longestStreak: number; peakHour: number | null; favoriteModel: string | null; dailyActivity: number[]; dailyStart: string | null; modelTokens: { model: string; tokens: number }[] }
type RestoredMessage = { role: "user" | "assistant"; text: string }
type RuntimeFrame = { id: string; type: "event" | "response"; ok: boolean; sessionID?: string; event?: { type: string; id?: string; text?: string; tool?: string; risk?: string; kind?: string; error?: string; reason?: string; sequence?: number; command?: string; exitCode?: number; workerID?: string; workerType?: string; summary?: string; evidenceCount?: number; currentRunCount?: number; staleRunCount?: number; state?: string; reasons?: string[]; url?: string; ok?: boolean; consoleErrorCount?: number; networkCount?: number; repairSessionID?: string; runID?: number; commit?: string; status?: string; delivery?: string; hostID?: string; remoteTool?: string; indeterminate?: boolean; terminalID?: string; attached?: boolean; number?: number; body?: string; inputTokens?: number; cachedInputTokens?: number; outputTokens?: number; route?: string; modelTier?: string; responseContract?: string; inputID?: string; preview?: string; name?: string; names?: string[]; warnings?: string[] }; result?: { text?: string; status?: string }; error?: string }
type Message = { role: "user" | "assistant" | "tool" | "system"; text: string; kind?: string }
type Approval = { id: string; tool: string; risk: string; preview?: string }
type Usage = { input: number; output: number; cached: number }

type ConversationItem = { key: string } & (
  | { kind: "message"; message: Message }
  | { kind: "toolGroup"; activities: Message[] }
)

const TOOL_ACTIVITY_KINDS = new Set(["tool_requested", "tool_started", "tool_completed", "terminal_completed", "ssh_terminal_opened", "ssh_terminal_completed", "ssh_terminal_closed", "ssh_completed"])

/** 连续的工具活动合并为一个可折叠分组，时间线保持干净。 */
function groupConversation(messages: Message[]): ConversationItem[] {
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

function ToolActivityGroup({ activities }: { activities: Message[] }) {
  const failed = activities.filter((activity) => activity.kind === "tool_completed" && /失败|错误/.test(activity.text)).length
  const latest = activities[activities.length - 1]?.text ?? ""
  return <details className="tool-group">
    <summary>
      <span className="tool-group-title">工具活动 · {activities.length} 步{failed > 0 ? ` · ${failed} 个失败` : ""}</span>
      <span className="tool-group-latest">{latest}</span>
    </summary>
    <div className="tool-group-items">{activities.map((activity, index) => <div className="tool-group-item" key={index}>{activity.text}</div>)}</div>
  </details>
}

function formatTokens(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`
  return String(value)
}

const STAT_RANGES = [{ key: "all", label: "全部", days: undefined }, { key: "30d", label: "30 天", days: 30 }, { key: "7d", label: "7 天", days: 7 }] as const
type StatRangeKey = typeof STAT_RANGES[number]["key"]

const QUICK_ACTIONS = [
  { icon: "🐞", label: "修复 Bug", prompt: "定位并修复当前项目中最严重的一个问题，修复后运行相关测试验证。" },
  { icon: "🔍", label: "理解代码", prompt: "梳理当前项目的整体架构，说明核心模块的职责和它们之间的交互。" },
  { icon: "🌐", label: "联网研究", prompt: "联网查询本项目主要依赖的最新官方文档，总结与当前版本相关的重要变化。" },
  { icon: "✅", label: "运行测试", prompt: "运行当前项目的测试套件，分析失败用例的根因并修复。" },
]

function Heatmap({ stats }: { stats: UsageStats }) {
  const cells = stats.dailyActivity
  const max = Math.max(1, ...cells)
  const padded = [...cells]
  while (padded.length % 7 !== 0) padded.push(0)
  const weeks: number[][] = []
  for (let index = 0; index < padded.length; index += 7) weeks.push(padded.slice(index, index + 7))
  return <div className="heatmap" role="img" aria-label="活动热力图">
    {weeks.map((week, weekIndex) => <div className="heatmap-week" key={weekIndex}>{week.map((count, dayIndex) => {
      const level = count === 0 ? 0 : Math.min(4, 1 + Math.floor((count / max) * 3.999))
      return <i key={dayIndex} className={`heatmap-cell level-${level}`} title={`${count} 个事件`} />
    })}</div>)}
  </div>
}

function StatsPanel({ stats, range, onRangeChange }: { stats: UsageStats | null; range: StatRangeKey; onRangeChange: (next: StatRangeKey) => void }) {
  const [tab, setTab] = useState<"overview" | "models">("overview")
  if (!stats) return null
  const cards: { label: string; value: string }[] = [
    { label: "会话", value: String(stats.sessions) },
    { label: "消息", value: stats.messages.toLocaleString() },
    { label: "总 Token", value: formatTokens(stats.totalTokens) },
    { label: "活跃天数", value: String(stats.activeDays) },
    { label: "当前连续", value: stats.currentStreak > 0 ? `${stats.currentStreak} 天` : "—" },
    { label: "最长连续", value: stats.longestStreak > 0 ? `${stats.longestStreak} 天` : "—" },
    { label: "高峰时段", value: stats.peakHour !== null ? `${stats.peakHour}:00` : "—" },
    { label: "常用模型", value: stats.favoriteModel ?? "—" },
  ]
  const maxModelTokens = Math.max(1, ...stats.modelTokens.map((row) => row.tokens))
  const books = Math.floor(stats.totalTokens / 1_000_000)
  return <section className="stats-card">
    <header className="stats-header">
      <nav className="stats-tabs">
        <button type="button" className={tab === "overview" ? "active" : ""} onClick={() => setTab("overview")}>概览</button>
        <button type="button" className={tab === "models" ? "active" : ""} onClick={() => setTab("models")}>模型</button>
      </nav>
      <nav className="stats-ranges">{STAT_RANGES.map((item) => <button key={item.key} type="button" className={range === item.key ? "active" : ""} onClick={() => onRangeChange(item.key)}>{item.label}</button>)}</nav>
    </header>
    {tab === "overview" && <>
      <div className="stats-grid">{cards.map((card) => <div className="stat-card" key={card.label}><span>{card.label}</span><strong>{card.value}</strong></div>)}</div>
      <Heatmap stats={stats} />
      <p className="stats-fun">{books >= 1 ? `你的累计 Token 用量已超过 ${books} 本《红楼梦》。` : stats.totalTokens > 0 ? `累计 ${formatTokens(stats.totalTokens)} Token——再努力一点就赶上一本《红楼梦》了。` : "还没有 Token 记录，从第一个任务开始积累。"}</p>
    </>}
    {tab === "models" && <div className="model-rows">
      {stats.modelTokens.length === 0 && <p className="stats-fun">暂无模型用量数据。</p>}
      {stats.modelTokens.map((row) => <div className="model-row" key={row.model}><span className="model-name" title={row.model}>{row.model}</span><div className="model-bar"><i style={{ width: `${Math.max(2, (row.tokens / maxModelTokens) * 100)}%` }} /></div><span className="model-tokens">{formatTokens(row.tokens)}</span></div>)}
    </div>}
  </section>
}

function projectGroupName(projectPath: string): string {
  if (!projectPath) return "未关联项目"
  const parts = projectPath.split("/").filter(Boolean)
  return parts.at(-1) ?? projectPath
}

function groupSessionsByProject(sessions: SessionSummary[]): { name: string; sessions: SessionSummary[] }[] {
  const groups = new Map<string, SessionSummary[]>()
  for (const session of sessions) {
    const name = projectGroupName(session.projectPath)
    const existing = groups.get(name) ?? []
    existing.push(session)
    groups.set(name, existing)
  }
  return [...groups.entries()].map(([name, grouped]) => ({ name, sessions: grouped }))
}

const defaults: Settings = { baseUrl: "https://api.deepseek.com/v1", model: "deepseek-chat", fastModel: "", projectPath: "", apiKey: "", protocol: "openai-compatible" }

function newSessionID(): string { return `session-${Date.now()}` }

function initialSessionID(): string {
  try { return localStorage.getItem("deepseek-code.active-session") || newSessionID() }
  catch { return newSessionID() }
}

function App() {
  const [runtime, setRuntime] = useState<RuntimeStatus>({ ready: false, version: "检查中" })
  const [buildStamp, setBuildStamp] = useState("加载中")
  const [settings, setSettings] = useState<Settings>(defaults)
  const [prompt, setPrompt] = useState("")
  const [messages, setMessages] = useState<Message[]>([])
  const [busy, setBusy] = useState(false)
  const [approval, setApproval] = useState<Approval | null>(null)
  const [showSettings, setShowSettings] = useState(false)
  const [sessionID, setSessionID] = useState(initialSessionID)
  const [sessions, setSessions] = useState<SessionSummary[]>([])
  const [usage, setUsage] = useState<Usage>({ input: 0, output: 0, cached: 0 })
  const [currentRoute, setCurrentRoute] = useState<string>("")
  const [stats, setStats] = useState<UsageStats | null>(null)
  const [statsRange, setStatsRange] = useState<StatRangeKey>("all")
  const seenFrameIDs = useRef(new Set<string>())

  async function refreshSessions() {
    const summaries = await invoke<SessionSummary[]>("list_sessions")
    setSessions(summaries)
  }

  async function refreshStats(range: StatRangeKey = statsRange) {
    const days = STAT_RANGES.find((item) => item.key === range)?.days
    const result = await invoke<UsageStats>("usage_stats", { days: days ?? null })
    setStats(result)
  }

  function changeStatsRange(range: StatRangeKey) {
    setStatsRange(range)
    void refreshStats(range).catch(() => undefined)
  }

  function applyQuickAction(actionPrompt: string) {
    setPrompt(actionPrompt)
    document.querySelector<HTMLTextAreaElement>(".composer textarea")?.focus()
  }

  async function openSession(nextSessionID: string) {
    if (busy) return
    const history = await invoke<RestoredMessage[]>("load_session_history", { sessionId: nextSessionID })
    setSessionID(nextSessionID)
    setMessages(history.map((message) => ({ role: message.role, text: message.text })))
    setApproval(null)
    try { localStorage.setItem("deepseek-code.active-session", nextSessionID) } catch { /* Local recovery remains optional in restricted webviews. */ }
    // If the session was interrupted, offer to resume any safely recoverable work.
    if (settings.apiKey.trim() && settings.projectPath.trim()) {
      void invoke("resume_session", { request: { sessionId: nextSessionID, projectPath: settings.projectPath, baseUrl: settings.baseUrl, apiKey: settings.apiKey, model: settings.model, protocol: settings.protocol, mode: "auto" } }).catch(() => undefined)
    }
  }

  function beginNewSession() {
    const nextSessionID = newSessionID()
    setSessionID(nextSessionID)
    setMessages([])
    setPrompt("")
    setApproval(null)
    try { localStorage.setItem("deepseek-code.active-session", nextSessionID) } catch { /* Local recovery remains optional in restricted webviews. */ }
  }

  useEffect(() => {
    void Promise.all([invoke<RuntimeStatus>("runtime_status"), invoke<Settings>("load_settings"), invoke<SessionSummary[]>("list_sessions"), invoke<string>("build_stamp")])
      .then(async ([status, saved, summaries, stamp]) => {
        setRuntime(status)
        setBuildStamp(stamp)
        setSettings({ ...defaults, ...saved, protocol: saved.protocol || defaults.protocol })
        setSessions(summaries)
        void refreshStats().catch(() => undefined)
        const stored = initialSessionID()
        const restore = summaries.some((session) => session.sessionId === stored) ? stored : summaries[0]?.sessionId
        if (restore) await openSession(restore)
      })
      .catch((error: unknown) => setRuntime({ ready: false, version: "不可用", detail: String(error) }))
  }, [])

  // Keyboard flow: Esc stops the running turn; ⌘K focuses the session switcher.
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && busy) { event.preventDefault(); void cancel() }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault()
        void refreshSessions()
        const first = document.querySelector<HTMLButtonElement>(".session-list button")
        first?.focus()
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "n") { event.preventDefault(); beginNewSession() }
    }
    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  })

  useEffect(() => {
    let disposed = false
    const unlisten = listen<RuntimeFrame>("runtime-event", (event) => {
      if (disposed) return
      const frame = event.payload
      if (frame.sessionID && frame.sessionID !== sessionID) return
      if (!shouldRenderFrame(frame.id, seenFrameIDs.current)) return
      if (frame.type === "response") {
        if (frame.result?.text) setMessages((current) => {
          const last = current[current.length - 1]
          return last?.role === "assistant" && last.text === frame.result?.text ? current : [...current, { role: "assistant", text: frame.result?.text ?? "" }]
        })
        if (!frame.ok) setMessages((current) => [...current, { role: "system", text: frame.error ?? "任务执行失败", kind: "error" }])
        setBusy(false)
        void refreshSessions()
        return
      }
      const runtimeEvent = frame.event
      if (!runtimeEvent) return
      if (runtimeEvent.type === "assistant_text" && runtimeEvent.text) {
        setMessages((current) => {
          const last = current[current.length - 1]
          if (last?.role === "assistant" && last.kind === "stream") return [...current.slice(0, -1), { ...last, text: last.text + runtimeEvent.text }]
          return [...current, { role: "assistant", text: runtimeEvent.text ?? "", kind: "stream" }]
        })
      } else if (runtimeEvent.type === "tool_requested" || runtimeEvent.type === "tool_started") {
        setMessages((current) => [...current, { role: "tool", text: `${runtimeEvent.type === "tool_started" ? "执行" : "准备"} ${runtimeEvent.tool ?? "工具"}…`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "tool_completed") {
        setMessages((current) => [...current, { role: "tool", text: `${runtimeEvent.tool ?? "工具"} 已完成`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "tool_indeterminate") {
        setMessages((current) => [...current, { role: "system", text: `${runtimeEvent.tool ?? "工具"} 已启动但结果未知；不会自动重试。请检查实际状态后再继续。`, kind: "error" }])
      } else if (runtimeEvent.type === "ssh_completed") {
        const state = runtimeEvent.indeterminate ? "结果未知" : runtimeEvent.ok ? "已完成" : "失败"
        setMessages((current) => [...current, { role: runtimeEvent.indeterminate || !runtimeEvent.ok ? "system" : "tool", text: `SSH · ${runtimeEvent.hostID ?? "主机"} · ${runtimeEvent.remoteTool ?? "远程工具"}：${state}`, kind: runtimeEvent.indeterminate || !runtimeEvent.ok ? "error" : runtimeEvent.type }])
      } else if (runtimeEvent.type === "ssh_terminal_opened") {
        setMessages((current) => [...current, { role: "tool", text: `SSH 终端 · ${runtimeEvent.hostID ?? "主机"}${runtimeEvent.attached ? " · 已恢复" : " · 已连接"}`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "ssh_terminal_completed") {
        const state = runtimeEvent.state === "indeterminate" ? "结果未知，不会自动重试" : `退出码 ${runtimeEvent.exitCode ?? "?"}`
        setMessages((current) => [...current, { role: runtimeEvent.state === "indeterminate" ? "system" : "tool", text: `SSH 终端 #${runtimeEvent.sequence ?? ""}：${state}`, kind: runtimeEvent.state === "indeterminate" ? "error" : runtimeEvent.type }])
      } else if (runtimeEvent.type === "ssh_terminal_closed") {
        setMessages((current) => [...current, { role: "tool", text: `SSH 终端 · ${runtimeEvent.hostID ?? "主机"} · 已关闭`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "terminal_completed") {
        setMessages((current) => [...current, { role: "tool", text: `终端 #${runtimeEvent.sequence ?? ""}：${runtimeEvent.command ?? "命令"}（退出码 ${runtimeEvent.exitCode ?? "?"}）`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "worker_completed") {
        setMessages((current) => [...current, { role: "tool", text: `${runtimeEvent.workerType ?? "Worker"} 已完成：${runtimeEvent.summary ?? ""}（${runtimeEvent.evidenceCount ?? 0} 条 Evidence）`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "ci_status") {
        setMessages((current) => [...current, { role: "tool", text: `GitHub Actions：当前 Commit ${runtimeEvent.currentRunCount ?? 0} 个 Run，忽略 ${runtimeEvent.staleRunCount ?? 0} 个旧 Commit Run`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "ci_repair_session_created") {
        setMessages((current) => [...current, { role: "tool", text: `CI 修复会话已创建：Run #${runtimeEvent.runID ?? "?"} · ${runtimeEvent.summary ?? "等待主任务安全结束后启动"}`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "ci_repair_session_started") {
        setMessages((current) => [...current, { role: "tool", text: `CI 修复会话已启动：Run #${runtimeEvent.runID ?? "?"} · Commit ${(runtimeEvent.commit ?? "").slice(0, 12)}`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "ci_repair_session_completed") {
        setMessages((current) => [...current, { role: "tool", text: `CI 修复会话结束：${runtimeEvent.status ?? "completed"}${runtimeEvent.delivery ? ` · ${runtimeEvent.delivery}` : ""}${runtimeEvent.summary ? ` · ${runtimeEvent.summary}` : ""}`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "ci_repair_session_failed") {
        setMessages((current) => [...current, { role: "system", text: `CI 修复会话失败：${runtimeEvent.error ?? "未知错误"}`, kind: "error" }])
      } else if (runtimeEvent.type === "ci_repair_pr_update_ready") {
        setMessages((current) => [...current, { role: "system", text: `CI 修复已完成，等待确认回写原始 PR #${runtimeEvent.number ?? "?"}。`, kind: "approval" }])
      } else if (runtimeEvent.type === "github_pr_updated") {
        setMessages((current) => [...current, { role: "tool", text: `已回写原始 PR #${runtimeEvent.number ?? "?"}。`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "recovery_attention") {
        setMessages((current) => [...current, { role: "system", text: `恢复提示：${runtimeEvent.error ?? runtimeEvent.reason ?? "存在需要关注的中断状态"}`, kind: "error" }])
      } else if (runtimeEvent.type === "recovery_input_restored") {
        setMessages((current) => [...current, { role: "tool", text: "已恢复一条中断的输入，将继续处理。", kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "skill_invoked") {
        setMessages((current) => [...current, { role: "tool", text: `已加载技能 /${runtimeEvent.name ?? ""}`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "hook_blocked") {
        setMessages((current) => [...current, { role: "system", text: `Hook 阻止了${runtimeEvent.kind === "userPromptSubmit" ? "本次输入" : "操作"}：${runtimeEvent.reason ?? "未说明原因"}`, kind: "error" }])
      } else if (runtimeEvent.type === "extension_loaded") {
        const warnings = runtimeEvent.warnings?.length ? `（${runtimeEvent.warnings.length} 个警告）` : ""
        if (runtimeEvent.names?.length || warnings) setMessages((current) => [...current, { role: "tool", text: `扩展已加载：${runtimeEvent.names?.join("、") || "无"}${warnings}`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "usage_recorded") {
        setUsage((current) => ({ input: current.input + (runtimeEvent.inputTokens ?? 0), output: current.output + (runtimeEvent.outputTokens ?? 0), cached: current.cached + (runtimeEvent.cachedInputTokens ?? 0) }))
      } else if (runtimeEvent.type === "decision_made") {
        setCurrentRoute(runtimeEvent.route ?? "")
      } else if (runtimeEvent.type === "delivery_evaluated") {
        const label: Record<string, string> = { delivered: "已交付", handoffReady: "待交接", needsRepair: "需要修复", needsAttention: "需要关注" }
        setMessages((current) => [...current, { role: "tool", text: `交付门禁：${label[runtimeEvent.state ?? ""] ?? runtimeEvent.state}${runtimeEvent.reasons?.length ? ` · ${runtimeEvent.reasons.join(" ")}` : ""}`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "browser_evidence") {
        setMessages((current) => [...current, { role: "tool", text: `浏览器验收：${runtimeEvent.ok ? "通过" : "失败"} · ${runtimeEvent.url ?? ""} · ${runtimeEvent.consoleErrorCount ?? 0} 个 Console Error，${runtimeEvent.networkCount ?? 0} 个 Network 响应`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "approval_required" && runtimeEvent.id) {
        setApproval({ id: runtimeEvent.id, tool: runtimeEvent.tool ?? "操作", risk: runtimeEvent.risk ?? "L2", preview: runtimeEvent.preview })
        setBusy(false)
      } else if (runtimeEvent.type === "failed" || runtimeEvent.type === "turn_ended" && runtimeEvent.reason === "error") {
        setMessages((current) => [...current, { role: "system", text: runtimeEvent.error ?? "任务执行失败", kind: "error" }])
        setBusy(false)
      } else if (runtimeEvent.type === "completed" || runtimeEvent.type === "turn_ended") {
        setBusy(false)
        if (runtimeEvent.type === "turn_ended") { void refreshSessions(); void refreshStats().catch(() => undefined) }
      }
    })
    return () => { disposed = true; void unlisten.then((stop) => stop()) }
  }, [sessionID])

  const canRun = useMemo(() => canSubmitTask({ runtimeReady: runtime.ready, busy, text: prompt, apiKey: settings.apiKey, projectPath: settings.projectPath }), [runtime.ready, busy, prompt, settings.apiKey, settings.projectPath])

  async function submit() {
    const text = prompt.trim()
    if (!text) return
    if (!settings.projectPath.trim() || !settings.apiKey.trim()) { setShowSettings(true); return }
    setMessages((current) => [...current, { role: "user", text }])
    setPrompt("")
    setBusy(true)
    try {
      try { localStorage.setItem("deepseek-code.active-session", sessionID) } catch { /* Session recovery remains optional in restricted webviews. */ }
      await invoke("save_settings", { settings })
      await invoke("run_agent", { request: { sessionId: sessionID, projectPath: settings.projectPath, prompt: text, baseUrl: settings.baseUrl, apiKey: settings.apiKey, model: settings.model, fastModel: settings.fastModel ?? "", protocol: settings.protocol, mode: "auto" } })
    } catch (error) {
      setBusy(false)
      setMessages((current) => [...current, { role: "system", text: String(error), kind: "error" }])
    }
  }

  async function resolveApproval(decision: "allow" | "deny") {
    if (!approval) return
    setBusy(true)
    try {
      await invoke("resolve_approval", { request: { sessionId: sessionID, projectPath: settings.projectPath, baseUrl: settings.baseUrl, apiKey: settings.apiKey, model: settings.model, protocol: settings.protocol, mode: "auto", approvalId: approval.id, decision } })
      setApproval(null)
    } catch (error) {
      setBusy(false)
      setMessages((current) => [...current, { role: "system", text: String(error), kind: "error" }])
    }
  }

  async function cancel() {
    try { await invoke("cancel_session", { request: { sessionId: sessionID } }) }
    catch (error) { setMessages((current) => [...current, { role: "system", text: String(error), kind: "error" }]) }
  }

  return <main className="shell">
    <aside className="sidebar">
      <div className="brand"><span>◆</span><strong>DeepSeek Code</strong></div>
      <button className="new-session" type="button" onClick={beginNewSession}>＋ 新建任务</button>
      <nav><button className="active" type="button">会话</button><button type="button" onClick={() => setShowSettings(true)}>设置</button><button type="button">终端</button><button type="button">用量</button></nav>
      <div className="session-list" aria-label="已保存会话">{groupSessionsByProject(sessions.slice(0, 24)).map((group) => <div className="session-group" key={group.name}>
        <p className="session-group-name">{group.name}</p>
        {group.sessions.map((session) => <button key={session.sessionId} className={session.sessionId === sessionID ? "active-session" : ""} type="button" onClick={() => void openSession(session.sessionId)} title={session.title}>{session.title}</button>)}
      </div>)}</div>
      <div className="privacy">本地优先 · 凭据保存在 Keychain</div>
    </aside>
    <section className="workspace">
      <header><div><p>DEEPSEEK CODE / LOCAL AGENT</p><h1>{messages.length ? "正在协作解决问题" : "✦ 接下来做点什么？"}</h1></div><span className={runtime.ready ? "runtime ready" : "runtime"}>{runtime.ready ? `● ${runtime.version}` : "○ Runtime 不可用"}<small className="build-stamp"> · Build {buildStamp}</small></span></header>
      {(usage.input > 0 || usage.output > 0 || currentRoute) && <div className="usage-bar">{currentRoute && <span className="route-chip">{currentRoute}</span>}<span>输入 {usage.input.toLocaleString()}{usage.cached > 0 ? `（缓存 ${usage.cached.toLocaleString()}）` : ""}</span><span>输出 {usage.output.toLocaleString()}</span><span>模型 {settings.model}{settings.fastModel ? ` · 快速 ${settings.fastModel}` : ""}</span></div>}
      {runtime.detail && <div className="notice error">Runtime: {runtime.detail}</div>}
      <section className={messages.length ? "conversation" : "conversation home"} aria-live="polite">
        {!messages.length && <>
          {(!settings.apiKey.trim() || !settings.projectPath.trim()) && <p className="setup-hint">先在<button type="button" className="setup-link" onClick={() => setShowSettings(true)}>设置</button>里配置项目目录和 API Key，然后直接描述任务。</p>}
          <StatsPanel stats={stats} range={statsRange} onRangeChange={changeStatsRange} />
          <div className="quick-actions">{QUICK_ACTIONS.map((action) => <button key={action.label} type="button" onClick={() => applyQuickAction(action.prompt)}><span>{action.icon}</span>{action.label}</button>)}</div>
        </>}
        {groupConversation(messages).map((item) => item.kind === "toolGroup"
          ? <ToolActivityGroup key={item.key} activities={item.activities} />
          : <article className={`message ${item.message.role} ${item.message.kind ?? ""}`} key={item.key}><span className="message-label">{item.message.role === "user" ? "你" : item.message.role === "tool" ? "Runtime" : item.message.role === "system" ? "系统" : "DeepSeek"}</span><div>{item.message.text}</div></article>)}
        {approval && <section className="approval"><header><strong>需要确认</strong><span className={`risk-badge risk-${approval.risk.toLowerCase()}`}>{approval.risk}</span></header><span>{approval.tool} 将执行受控操作。</span>{approval.preview && <code className="approval-preview">{approval.preview}</code>}<div><button type="button" onClick={() => void resolveApproval("deny")}>取消</button><button className="allow" type="button" onClick={() => void resolveApproval("allow")}>允许一次</button></div></section>}
        {busy && <div className="typing"><i /><i /><i /> 正在工作</div>}
      </section>
      <section className="composer"><textarea aria-label="任务描述" value={prompt} onChange={(event) => setPrompt(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); void submit() } }} placeholder="例如：定位登录状态不同步的问题，修复后运行相关测试。" /><footer><span>{busy ? "Agent 正在执行；Esc 停止 · 新消息会排队到安全边界" : "回车发送 · Shift+Enter 换行 · ⌘K 切换会话 · ⌘N 新任务"}</span>{busy && <button type="button" onClick={() => void cancel()}>停止</button>}<button type="button" disabled={!canRun} onClick={() => void submit()}>{submitActionLabel(busy)}</button></footer></section>
      {showSettings && <div className="settings-backdrop" onClick={() => setShowSettings(false)}><section className="settings" onClick={(event) => event.stopPropagation()}><header><div><p>LOCAL CONFIGURATION</p><h2>连接与项目</h2></div><button type="button" onClick={() => setShowSettings(false)}>×</button></header><label>项目目录<input value={settings.projectPath} onChange={(event) => setSettings({ ...settings, projectPath: event.target.value })} placeholder="/Users/you/Projects/my-app" /></label><label>协议<select value={settings.protocol} onChange={(event) => setSettings({ ...settings, protocol: event.target.value as Settings["protocol"] })}><option value="openai-compatible">OpenAI-compatible / DeepSeek</option><option value="anthropic-messages">Anthropic Messages</option></select></label><label>Base URL<input value={settings.baseUrl} onChange={(event) => setSettings({ ...settings, baseUrl: event.target.value })} /></label><label>主模型（复杂任务/编码）<input value={settings.model} onChange={(event) => setSettings({ ...settings, model: event.target.value })} /></label><label>快速模型（简单问答/分类，可留空）<input value={settings.fastModel ?? ""} onChange={(event) => setSettings({ ...settings, fastModel: event.target.value })} placeholder="留空则全部使用主模型" /></label><label>API Key<input type="password" value={settings.apiKey} onChange={(event) => setSettings({ ...settings, apiKey: event.target.value })} placeholder="只写入 macOS Keychain" /></label><button className="save" type="button" onClick={() => { void invoke("save_settings", { settings }); setShowSettings(false) }}>保存配置</button></section></div>}
    </section>
  </main>
}

createRoot(document.getElementById("root")!).render(<App />)
