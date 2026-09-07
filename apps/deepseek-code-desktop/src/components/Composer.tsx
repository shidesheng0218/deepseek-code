import { useMemo, useRef, useState } from "react"
import { submitActionLabel } from "../interaction-policy"
import type { SkillInfo } from "../types"
import { Icon } from "./Icon"

/** 输入形如 "/pdf"（斜杠开头、尚未输入空格）时视为正在挑选 Skill。 */
function slashQuery(text: string): string | null {
  const match = /^\/([a-z0-9-_]*)$/i.exec(text)
  return match ? (match[1] ?? "") : null
}

export function Composer({ prompt, onPromptChange, busy, canRun, skills, onSubmit, onCancel }: {
  prompt: string
  onPromptChange: (next: string) => void
  busy: boolean
  canRun: boolean
  skills: SkillInfo[]
  onSubmit: () => void
  onCancel: () => void
}) {
  const [selected, setSelected] = useState(0)
  const [dismissed, setDismissed] = useState(false)
  const textareaRef = useRef<HTMLTextAreaElement>(null)

  const query = slashQuery(prompt)
  const matches = useMemo(() => {
    if (query === null || dismissed) return []
    const needle = query.toLowerCase()
    return skills.filter((skill) => skill.name.toLowerCase().includes(needle)).slice(0, 8)
  }, [query, skills, dismissed])

  const menuOpen = matches.length > 0

  function pick(skill: SkillInfo) {
    onPromptChange(`/${skill.name} `)
    setDismissed(false)
    setSelected(0)
    textareaRef.current?.focus()
  }

  function handleChange(next: string) {
    setDismissed(false)
    setSelected(0)
    onPromptChange(next)
  }

  function handleKeyDown(event: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (menuOpen) {
      if (event.key === "ArrowDown") { event.preventDefault(); setSelected((current) => (current + 1) % matches.length); return }
      if (event.key === "ArrowUp") { event.preventDefault(); setSelected((current) => (current - 1 + matches.length) % matches.length); return }
      if (event.key === "Enter" || event.key === "Tab") { event.preventDefault(); pick(matches[Math.min(selected, matches.length - 1)]); return }
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); setDismissed(true); return }
    }
    if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); onSubmit() }
  }

  return <section className="composer">
    {menuOpen && <div className="slash-menu" role="listbox" aria-label="可用技能">
      {matches.map((skill, index) => <button
        key={skill.name}
        type="button"
        role="option"
        aria-selected={index === selected}
        className={index === selected ? "active" : ""}
        onMouseEnter={() => setSelected(index)}
        onClick={() => pick(skill)}
      >
        <span className="slash-name">/{skill.name}</span>
        {skill.description && <span className="slash-desc">{skill.description}</span>}
        {skill.location && <span className="slash-loc">{skill.location === "project" ? "项目" : "用户"}</span>}
      </button>)}
    </div>}
    <textarea
      ref={textareaRef}
      aria-label="任务描述"
      value={prompt}
      onChange={(event) => handleChange(event.target.value)}
      onKeyDown={handleKeyDown}
      placeholder={skills.length ? "描述任务，或输入 / 调用技能。" : "例如：定位登录状态不同步的问题，修复后运行相关测试。"}
    />
    <footer>
      <span>{busy ? "Agent 正在执行；Esc 停止 · 新消息会排队到安全边界" : "回车发送 · Shift+Enter 换行 · / 技能 · ⌘K 切换会话 · ⌘N 新任务"}</span>
      {busy && <button type="button" onClick={onCancel}><Icon name="stop" />停止</button>}
      <button type="button" disabled={!canRun} onClick={onSubmit}><Icon name="send" />{submitActionLabel(busy)}</button>
    </footer>
  </section>
}
