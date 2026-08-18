import { invoke } from "@tauri-apps/api/core"
import { useEffect, useState } from "react"
import { createRoot } from "react-dom/client"
import "./styles.css"

type RuntimeStatus = { ready: boolean; version: string; detail?: string }

function App() {
  const [runtime, setRuntime] = useState<RuntimeStatus>({ ready: false, version: "检查中" })

  useEffect(() => {
    void invoke<RuntimeStatus>("runtime_status")
      .then(setRuntime)
      .catch((error: unknown) => setRuntime({ ready: false, version: "不可用", detail: String(error) }))
  }, [])

  return <main className="shell">
    <aside className="sidebar"><div className="brand"><span>◆</span><strong>DeepSeek Code</strong></div><button className="new-session" type="button">＋ 新建任务</button><nav><button className="active" type="button">会话</button><button type="button">项目</button><button type="button">终端</button><button type="button">用量</button></nav><div className="privacy">本地优先 · 凭据受保护</div></aside>
    <section className="workspace"><header><div><p>DEEPSEEK CODE / LOCAL AGENT</p><h1>准备开始一个任务</h1></div><span className={runtime.ready ? "runtime ready" : "runtime"}>{runtime.ready ? "● Runtime 已就绪" : "○ Runtime 检查中"}</span></header><section className="welcome-card"><h2>自己的轻量编码工作台</h2><p>对话、工具、终端和验证将由本地 Agent Runtime 统一执行。所有产品数据、权限和证据都属于 DeepSeek Code。</p>{runtime.detail && <small>Runtime: {runtime.detail}</small>}</section><section className="composer"><textarea aria-label="任务描述" placeholder="例如：定位登录状态不同步的问题，修复后运行相关测试。" /><footer><span>公开只读研究自动执行；写入和外部交付仍受控。</span><button type="button" disabled={!runtime.ready}>开始任务</button></footer></section></section>
  </main>
}

createRoot(document.getElementById("root")!).render(<App />)
