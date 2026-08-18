import { invoke } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { useEffect, useMemo, useState } from "react"
import { createRoot } from "react-dom/client"
import "./styles.css"

type RuntimeStatus = { ready: boolean; version: string; detail?: string }
type Settings = { baseUrl: string; model: string; projectPath: string; apiKey: string }
type RuntimeFrame = { id: string; type: "event" | "response"; ok: boolean; sessionID?: string; event?: { type: string; id?: string; text?: string; tool?: string; risk?: string; error?: string; reason?: string }; result?: { text?: string; status?: string }; error?: string }
type Message = { role: "user" | "assistant" | "tool" | "system"; text: string; kind?: string }
type Approval = { id: string; tool: string; risk: string }

const defaults: Settings = { baseUrl: "https://api.deepseek.com/v1", model: "deepseek-chat", projectPath: "", apiKey: "" }

function App() {
  const [runtime, setRuntime] = useState<RuntimeStatus>({ ready: false, version: "检查中" })
  const [settings, setSettings] = useState<Settings>(defaults)
  const [prompt, setPrompt] = useState("")
  const [messages, setMessages] = useState<Message[]>([])
  const [busy, setBusy] = useState(false)
  const [approval, setApproval] = useState<Approval | null>(null)
  const [showSettings, setShowSettings] = useState(false)
  const [sessionID] = useState(() => `session-${Date.now()}`)

  useEffect(() => {
    void Promise.all([invoke<RuntimeStatus>("runtime_status"), invoke<Settings>("load_settings")])
      .then(([status, saved]) => { setRuntime(status); setSettings({ ...defaults, ...saved }) })
      .catch((error: unknown) => setRuntime({ ready: false, version: "不可用", detail: String(error) }))
  }, [])

  useEffect(() => {
    let disposed = false
    const unlisten = listen<RuntimeFrame>("runtime-event", (event) => {
      if (disposed) return
      const frame = event.payload
      if (frame.type === "response") {
        if (frame.result?.text) setMessages((current) => {
          const last = current[current.length - 1]
          return last?.role === "assistant" && last.text === frame.result?.text ? current : [...current, { role: "assistant", text: frame.result?.text ?? "" }]
        })
        if (!frame.ok) setMessages((current) => [...current, { role: "system", text: frame.error ?? "任务执行失败", kind: "error" }])
        setBusy(false)
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
      } else if (runtimeEvent.type === "approval_required" && runtimeEvent.id) {
        setApproval({ id: runtimeEvent.id, tool: runtimeEvent.tool ?? "操作", risk: runtimeEvent.risk ?? "L2" })
        setBusy(false)
      } else if (runtimeEvent.type === "failed" || runtimeEvent.type === "turn_ended" && runtimeEvent.reason === "error") {
        setMessages((current) => [...current, { role: "system", text: runtimeEvent.error ?? "任务执行失败", kind: "error" }])
        setBusy(false)
      } else if (runtimeEvent.type === "completed" || runtimeEvent.type === "turn_ended") {
        setBusy(false)
      }
    })
    return () => { disposed = true; void unlisten.then((stop) => stop()) }
  }, [])

  const canRun = useMemo(() => runtime.ready && !busy && Boolean(prompt.trim()) && Boolean(settings.apiKey.trim()) && Boolean(settings.projectPath.trim()), [runtime.ready, busy, prompt, settings])

  async function submit() {
    const text = prompt.trim()
    if (!text || busy) return
    if (!settings.projectPath.trim() || !settings.apiKey.trim()) { setShowSettings(true); return }
    setMessages((current) => [...current, { role: "user", text }])
    setPrompt("")
    setBusy(true)
    try {
      await invoke("save_settings", { settings })
      await invoke("run_agent", { request: { sessionId: sessionID, projectPath: settings.projectPath, prompt: text, baseUrl: settings.baseUrl, apiKey: settings.apiKey, model: settings.model, mode: "auto" } })
    } catch (error) {
      setBusy(false)
      setMessages((current) => [...current, { role: "system", text: String(error), kind: "error" }])
    }
  }

  async function resolveApproval(decision: "allow" | "deny") {
    if (!approval) return
    setBusy(true)
    try {
      await invoke("resolve_approval", { request: { sessionId: sessionID, projectPath: settings.projectPath, baseUrl: settings.baseUrl, apiKey: settings.apiKey, model: settings.model, mode: "auto", approvalId: approval.id, decision } })
      setApproval(null)
    } catch (error) {
      setBusy(false)
      setMessages((current) => [...current, { role: "system", text: String(error), kind: "error" }])
    }
  }

  return <main className="shell">
    <aside className="sidebar">
      <div className="brand"><span>◆</span><strong>DeepSeek Code</strong></div>
      <button className="new-session" type="button" onClick={() => { setMessages([]); setPrompt(""); }}>＋ 新建任务</button>
      <nav><button className="active" type="button">会话</button><button type="button" onClick={() => setShowSettings(true)}>设置</button><button type="button">终端</button><button type="button">用量</button></nav>
      <div className="privacy">本地优先 · 凭据保存在 Keychain</div>
    </aside>
    <section className="workspace">
      <header><div><p>DEEPSEEK CODE / LOCAL AGENT</p><h1>{messages.length ? "正在协作解决问题" : "准备开始一个任务"}</h1></div><span className={runtime.ready ? "runtime ready" : "runtime"}>{runtime.ready ? `● ${runtime.version}` : "○ Runtime 不可用"}</span></header>
      {runtime.detail && <div className="notice error">Runtime: {runtime.detail}</div>}
      <section className="conversation" aria-live="polite">
        {!messages.length && <div className="welcome-card"><h2>自己的轻量编码工作台</h2><p>描述一个问题，DeepSeek Code 会在当前项目中理解、修改并验证。公开只读研究自动执行；写入和外部交付仍受控。</p><button type="button" onClick={() => setShowSettings(true)}>配置项目与模型</button></div>}
        {messages.map((message, index) => <article className={`message ${message.role} ${message.kind ?? ""}`} key={`${index}-${message.text.slice(0, 12)}`}><span className="message-label">{message.role === "user" ? "你" : message.role === "tool" ? "Runtime" : message.role === "system" ? "系统" : "DeepSeek"}</span><div>{message.text}</div></article>)}
        {approval && <section className="approval"><strong>需要确认</strong><span>{approval.tool}（{approval.risk}）将执行受控操作。</span><div><button type="button" onClick={() => void resolveApproval("deny")}>取消</button><button className="allow" type="button" onClick={() => void resolveApproval("allow")}>允许一次</button></div></section>}
        {busy && <div className="typing"><i /><i /><i /> 正在工作</div>}
      </section>
      <section className="composer"><textarea aria-label="任务描述" value={prompt} onChange={(event) => setPrompt(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); void submit() } }} placeholder="例如：定位登录状态不同步的问题，修复后运行相关测试。" /><footer><span>{busy ? "Agent 正在执行，事件会实时显示" : "回车发送 · Shift+Enter 换行"}</span><button type="button" disabled={!canRun} onClick={() => void submit()}>{busy ? "执行中…" : "开始任务"}</button></footer></section>
      {showSettings && <div className="settings-backdrop" onClick={() => setShowSettings(false)}><section className="settings" onClick={(event) => event.stopPropagation()}><header><div><p>LOCAL CONFIGURATION</p><h2>连接与项目</h2></div><button type="button" onClick={() => setShowSettings(false)}>×</button></header><label>项目目录<input value={settings.projectPath} onChange={(event) => setSettings({ ...settings, projectPath: event.target.value })} placeholder="/Users/you/Projects/my-app" /></label><label>Base URL<input value={settings.baseUrl} onChange={(event) => setSettings({ ...settings, baseUrl: event.target.value })} /></label><label>模型<input value={settings.model} onChange={(event) => setSettings({ ...settings, model: event.target.value })} /></label><label>API Key<input type="password" value={settings.apiKey} onChange={(event) => setSettings({ ...settings, apiKey: event.target.value })} placeholder="只写入 macOS Keychain" /></label><button className="save" type="button" onClick={() => { void invoke("save_settings", { settings }); setShowSettings(false) }}>保存配置</button></section></div>}
    </section>
  </main>
}

createRoot(document.getElementById("root")!).render(<App />)
