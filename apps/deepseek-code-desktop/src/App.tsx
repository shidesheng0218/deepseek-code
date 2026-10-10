import { invoke } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { open as openDialog } from "@tauri-apps/plugin-dialog"
import { useEffect, useMemo, useRef, useState } from "react"
import { canSubmitTask, shouldRenderFrame } from "./interaction-policy"
import { appendAssistantStream, reconcileFinalAssistantResponse, type Message, type SessionSummary } from "./conversation-grouping"
import { defaultSettings, type Approval, type RestoredMessage, type RuntimeFrame, type RuntimeStatus, type Settings, type SkillInfo, type UsageStats } from "./types"
import { applyTheme, loadThemePreference, saveThemePreference, watchSystemTheme, type ThemePreference } from "./theme"
import { waitForFrame } from "./runtime-frames"
import { Composer } from "./components/Composer"
import { Conversation, type ViewDensity } from "./components/Conversation"
import { QuickIcon } from "./components/Icon"
import { SettingsModal } from "./components/SettingsModal"
import { Sidebar, type ViewKey } from "./components/Sidebar"
import { STAT_RANGES, StatsPanel, type StatRangeKey } from "./components/StatsPanel"
import { TerminalPanel } from "./components/TerminalPanel"

const QUICK_ACTIONS = [
  { icon: "bug", label: "修复 Bug", prompt: "定位并修复当前项目中最严重的一个问题，修复后运行相关测试验证。" },
  { icon: "code", label: "理解代码", prompt: "梳理当前项目的整体架构，说明核心模块的职责和它们之间的交互。" },
  { icon: "globe", label: "联网研究", prompt: "联网查询本项目主要依赖的最新官方文档，总结与当前版本相关的重要变化。" },
  { icon: "play", label: "运行测试", prompt: "运行当前项目的测试套件，分析失败用例的根因并修复。" },
] as const

function newSessionID(): string { return `session-${Date.now()}` }

function initialSessionID(): string {
  try { return localStorage.getItem("deepseek-code.active-session") || newSessionID() }
  catch { return newSessionID() }
}

export function App() {
  const [runtime, setRuntime] = useState<RuntimeStatus>({ ready: false, version: "检查中" })
  const [buildStamp, setBuildStamp] = useState("加载中")
  const [settings, setSettings] = useState<Settings>(defaultSettings)
  const [prompt, setPrompt] = useState("")
  const [messages, setMessages] = useState<Message[]>([])
  const [busy, setBusy] = useState(false)
  const [approval, setApproval] = useState<Approval | null>(null)
  const [showSettings, setShowSettings] = useState(false)
  const [sessionID, setSessionID] = useState(initialSessionID)
  const [sessions, setSessions] = useState<SessionSummary[]>([])
  const [stats, setStats] = useState<UsageStats | null>(null)
  const [statsRange, setStatsRange] = useState<StatRangeKey>("all")
  const [view, setView] = useState<ViewKey>("chat")
  const [theme, setTheme] = useState<ThemePreference>(loadThemePreference)
  const [density, setDensity] = useState<ViewDensity>(() => {
    try {
      const stored = localStorage.getItem("deepseek-code.density")
      if (stored === "summary" || stored === "normal" || stored === "verbose") return stored
    } catch { /* Optional persistence. */ }
    return "normal"
  })
  const [skills, setSkills] = useState<SkillInfo[]>([])
  const seenFrameIDs = useRef(new Set<string>())

  useEffect(() => {
    applyTheme(theme)
    saveThemePreference(theme)
    if (theme !== "system") return
    return watchSystemTheme(() => applyTheme("system"))
  }, [theme])

  useEffect(() => {
    try { localStorage.setItem("deepseek-code.density", density) } catch { /* Optional persistence. */ }
  }, [density])

  // 技能清单跟随项目目录：切换项目后重新扫描 .deepseek/.claude skills，供 Composer 斜杠菜单使用。
  useEffect(() => {
    if (!runtime.ready) return
    let stale = false
    invoke<string>("list_skills", { request: { projectPath: settings.projectPath } })
      .then((requestID) => waitForFrame(requestID, 15_000))
      .then((frame) => { if (!stale && frame.ok) setSkills(frame.result?.skills ?? []) })
      .catch(() => { if (!stale) setSkills([]) })
    return () => { stale = true }
  }, [runtime.ready, settings.projectPath])

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

  function changeView(next: ViewKey) {
    setView(next)
    if (next === "usage") void refreshStats().catch(() => undefined)
  }

  function applyQuickAction(actionPrompt: string) {
    setPrompt(actionPrompt)
    document.querySelector<HTMLTextAreaElement>(".composer textarea")?.focus()
  }

  async function chooseProjectDirectory() {
    // Native Finder picker beats hand-typing an absolute path; falls back to the
    // existing manual input on cancel or on platforms where the dialog is unavailable.
    try {
      const selected = await openDialog({ directory: true, multiple: false, defaultPath: settings.projectPath || undefined })
      if (typeof selected === "string" && selected.trim()) setSettings((current) => ({ ...current, projectPath: selected }))
    } catch { /* User cancelled or dialog unavailable; manual input remains usable. */ }
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
      void invoke("resume_session", { request: { sessionId: nextSessionID, projectPath: settings.projectPath, baseUrl: settings.baseUrl, apiKey: settings.apiKey, model: settings.model, protocol: settings.protocol, mode: "auto" } })
        .catch((error: unknown) => setMessages((current) => [...current, { role: "system", text: `会话恢复失败：${String(error)}。历史消息不受影响，可直接继续输入新任务。`, kind: "error" }]))
    }
  }

  function beginNewSession() {
    const nextSessionID = newSessionID()
    setSessionID(nextSessionID)
    setMessages([])
    setPrompt("")
    setApproval(null)
    setView("chat")
    try { localStorage.setItem("deepseek-code.active-session", nextSessionID) } catch { /* Local recovery remains optional in restricted webviews. */ }
  }

  useEffect(() => {
    void Promise.all([invoke<RuntimeStatus>("runtime_status"), invoke<Settings>("load_settings"), invoke<SessionSummary[]>("list_sessions"), invoke<string>("build_stamp")])
      .then(async ([status, saved, summaries, stamp]) => {
        setRuntime(status)
        setBuildStamp(stamp)
        setSettings({ ...defaultSettings, ...saved, protocol: saved.protocol || defaultSettings.protocol })
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
        if (frame.result?.text) setMessages((current) => reconcileFinalAssistantResponse(current, frame.result?.text ?? ""))
        if (!frame.ok) setMessages((current) => [...current, { role: "system", text: frame.error ?? "任务执行失败", kind: "error" }])
        setBusy(false)
        void refreshSessions()
        return
      }
      const runtimeEvent = frame.event
      if (!runtimeEvent) return
      if (runtimeEvent.type === "assistant_text" && runtimeEvent.text) {
        setMessages((current) => appendAssistantStream(current, runtimeEvent.text ?? ""))
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
      } else if (runtimeEvent.type === "model_retrying") {
        setMessages((current) => [...current, { role: "tool", text: `模型请求失败，正在自动重试（第 ${runtimeEvent.attempt ?? "?"}/${runtimeEvent.maxAttempts ?? 3} 次）：${runtimeEvent.error ?? ""}`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "delivery_evaluated") {
        const label: Record<string, string> = { delivered: "已交付", handoffReady: "待交接", needsRepair: "需要修复", needsAttention: "需要关注" }
        setMessages((current) => [...current, { role: "tool", text: `交付门禁：${label[runtimeEvent.state ?? ""] ?? runtimeEvent.state}${runtimeEvent.reasons?.length ? ` · ${runtimeEvent.reasons.join(" ")}` : ""}`, kind: runtimeEvent.type }])
      } else if (runtimeEvent.type === "receipt_issued") {
        setMessages((current) => [...current, { role: "tool", text: `交付回执已签发：${(runtimeEvent.receiptID ?? "").slice(0, 8)} · ${runtimeEvent.evidenceCount ?? 0} 条证据哈希链`, kind: runtimeEvent.type }])
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

  const headline = view === "usage" ? "用量统计" : view === "terminal" ? "共享终端" : messages.length ? "正在协作解决问题" : "✦ 接下来做点什么？"

  const homeContent = <>
    {(!settings.apiKey.trim() || !settings.projectPath.trim()) && <p className="setup-hint">先在<button type="button" className="setup-link" onClick={() => setShowSettings(true)}>设置</button>里配置项目目录和 API Key，然后直接描述任务。</p>}
    <StatsPanel stats={stats} range={statsRange} onRangeChange={changeStatsRange} />
    <div className="quick-actions">{QUICK_ACTIONS.map((action) => <button key={action.label} type="button" onClick={() => applyQuickAction(action.prompt)}><span className="icon-tile"><QuickIcon name={action.icon} /></span>{action.label}</button>)}</div>
  </>

  return <main className="shell">
    <Sidebar
      view={view}
      sessions={sessions}
      activeSessionID={sessionID}
      onViewChange={changeView}
      onNewSession={beginNewSession}
      onOpenSettings={() => setShowSettings(true)}
      onOpenSession={(next) => { setView("chat"); void openSession(next) }}
    />
    <section className="workspace">
      <header data-tauri-drag-region><div><p>DEEPSEEK CODE / LOCAL AGENT</p><h1>{headline}</h1></div><div className="header-side">{view === "chat" && <nav className="density-switch" aria-label="视图密度">{([["summary", "简洁"], ["normal", "标准"], ["verbose", "详细"]] as const).map(([key, label]) => <button key={key} type="button" className={density === key ? "active" : ""} onClick={() => setDensity(key)}>{label}</button>)}</nav>}<span className={runtime.ready ? "runtime ready" : "runtime"}>{runtime.ready ? `● ${runtime.version}` : "○ Runtime 不可用"}<small className="build-stamp"> · Build {buildStamp}</small></span></div></header>
      {runtime.detail && <div className="notice error">Runtime: {runtime.detail}</div>}
      {view === "terminal" && <TerminalPanel sessionID={sessionID} projectPath={settings.projectPath} onRequireProject={() => setShowSettings(true)} />}
      {view === "usage" && <div className="usage-view"><StatsPanel stats={stats} range={statsRange} onRangeChange={changeStatsRange} /></div>}
      {view === "chat" && <>
        <Conversation messages={messages} approval={approval} busy={busy} home={homeContent} density={density} onResolveApproval={(decision) => void resolveApproval(decision)} />
        <Composer prompt={prompt} onPromptChange={setPrompt} busy={busy} canRun={canRun} skills={skills} onSubmit={() => void submit()} onCancel={() => void cancel()} />
      </>}
      {showSettings && <SettingsModal
        settings={settings}
        theme={theme}
        onSettingsChange={setSettings}
        onThemeChange={setTheme}
        onBrowse={() => void chooseProjectDirectory()}
        onSave={() => { void invoke("save_settings", { settings }); setShowSettings(false) }}
        onClose={() => setShowSettings(false)}
      />}
    </section>
  </main>
}
