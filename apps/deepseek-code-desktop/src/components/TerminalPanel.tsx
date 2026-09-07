import { invoke } from "@tauri-apps/api/core"
import { useEffect, useRef, useState } from "react"
import { waitForFrame } from "../runtime-frames"
import type { TerminalEntry } from "../types"

/**
 * 终端面板：与主对话共享同一个持久化 Shell（terminalFor(sessionID)），
 * 所以在这里 cd 到某个目录后，Agent 用 run_command 执行的命令也会在那个目录下跑——
 * 一个 Session、一份 Shell 状态。响应通过 sessionId-nanos 请求 id 在 runtime-event 流上
 * 一次性过滤，而不是复用会话消息流的"下一条 response 就是它"逻辑（终端可能连续敲多条命令）。
 */
export function TerminalPanel({ sessionID, projectPath, onRequireProject }: { sessionID: string; projectPath: string; onRequireProject: () => void }) {
  const [entries, setEntries] = useState<TerminalEntry[]>([])
  const [input, setInput] = useState("")
  const [running, setRunning] = useState(false)
  const [opened, setOpened] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const scrollRef = useRef<HTMLDivElement>(null)
  const openedForRef = useRef<string | null>(null)

  async function openTerminal() {
    if (!projectPath.trim()) { onRequireProject(); return }
    setError(null)
    try {
      const requestID = await invoke<string>("open_terminal", { request: { sessionId: sessionID, projectPath } })
      const frame = await waitForFrame(requestID)
      if (!frame.ok) { setError(frame.error ?? "终端启动失败"); return }
      setEntries(frame.result?.entries ?? [])
      setOpened(true)
      openedForRef.current = sessionID
    } catch (err) { setError(String(err)) }
  }

  useEffect(() => {
    // Switching sessions attaches to that session's own persistent shell; re-open lazily
    // on next command rather than eagerly spawning a shell for every session on load.
    if (openedForRef.current !== sessionID) { setOpened(false); setEntries([]) }
  }, [sessionID])

  useEffect(() => { scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight }) }, [entries])

  async function runCommand() {
    const command = input.trim()
    if (!command || running) return
    if (!projectPath.trim()) { onRequireProject(); return }
    setError(null)
    setRunning(true)
    setInput("")
    try {
      if (!opened) await openTerminal()
      const requestID = await invoke<string>("exec_terminal", { request: { sessionId: sessionID, projectPath, command } })
      const frame = await waitForFrame(requestID)
      if (!frame.ok) { setError(frame.error ?? "命令执行失败"); return }
      const result = frame.result
      setEntries((current) => [...current, {
        sequence: current.length ? current[current.length - 1].sequence + 1 : 1,
        command,
        stdout: result?.stdout ?? "",
        stderr: result?.stderr ?? "",
        exitCode: result?.exitCode ?? 0
      }])
    } catch (err) { setError(String(err)) }
    finally { setRunning(false) }
  }

  return <section className="terminal-panel">
    {!opened && <button type="button" className="terminal-connect" onClick={() => void openTerminal()}>连接终端 · {projectPath || "先在设置里选择项目目录"}</button>}
    {opened && <>
      <div className="terminal-output" ref={scrollRef}>
        {entries.length === 0 && <p className="terminal-empty">终端已连接，工作目录 {projectPath}。输入命令并回车执行。</p>}
        {entries.map((entry) => <div className="terminal-entry" key={entry.sequence}>
          <div className="terminal-command"><span>$</span>{entry.command}</div>
          {entry.stdout && <pre className="terminal-stdout">{entry.stdout}</pre>}
          {entry.stderr && <pre className="terminal-stderr">{entry.stderr}</pre>}
          {entry.exitCode !== 0 && <span className="terminal-exit">退出码 {entry.exitCode}</span>}
        </div>)}
      </div>
      <div className="terminal-input-row">
        <span className="terminal-prompt">$</span>
        <input
          className="terminal-input"
          value={input}
          disabled={running}
          onChange={(event) => setInput(event.target.value)}
          onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); void runCommand() } }}
          placeholder={running ? "执行中…" : "输入命令，回车执行"}
          autoFocus
        />
      </div>
    </>}
    {error && <p className="terminal-error">{error}</p>}
  </section>
}
