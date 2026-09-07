import { invoke } from "@tauri-apps/api/core"
import { useState } from "react"
import type { Settings, UpdateStatus } from "../types"
import type { ThemePreference } from "../theme"
import { applyProviderPreset, presetIdForBaseUrl, PROVIDER_PRESETS } from "../provider-presets"
import { Icon } from "./Icon"

export function SettingsModal({ settings, theme, onSettingsChange, onThemeChange, onBrowse, onSave, onClose }: {
  settings: Settings
  theme: ThemePreference
  onSettingsChange: (next: Settings) => void
  onThemeChange: (next: ThemePreference) => void
  onBrowse: () => void
  onSave: () => void
  onClose: () => void
}) {
  const [update, setUpdate] = useState<{ checking: boolean; result: UpdateStatus | null }>({ checking: false, result: null })

  async function checkForUpdate() {
    if (update.checking) return
    setUpdate({ checking: true, result: null })
    try {
      const result = await invoke<UpdateStatus>("check_for_update")
      setUpdate({ checking: false, result })
    } catch (error) {
      setUpdate({ checking: false, result: { available: false, detail: `检查失败：${String(error)}` } })
    }
  }

  return <div className="settings-backdrop" onClick={onClose}>
    <section className="settings" onClick={(event) => event.stopPropagation()}>
      <header>
        <div><p>LOCAL CONFIGURATION</p><h2>连接与项目</h2></div>
        <button type="button" onClick={onClose}><Icon name="x" /></button>
      </header>
      <label>项目目录<div className="path-row"><input value={settings.projectPath} onChange={(event) => onSettingsChange({ ...settings, projectPath: event.target.value })} placeholder="/Users/you/Projects/my-app" /><button type="button" className="browse" onClick={onBrowse}>浏览…</button></div></label>
      <label>服务商预设<select value={presetIdForBaseUrl(settings.baseUrl)} onChange={(event) => onSettingsChange(applyProviderPreset(settings, event.target.value))}>{PROVIDER_PRESETS.map((preset) => <option key={preset.id} value={preset.id}>{preset.label}</option>)}</select></label>
      <label>协议<select value={settings.protocol} onChange={(event) => onSettingsChange({ ...settings, protocol: event.target.value as Settings["protocol"] })}><option value="openai-compatible">OpenAI-compatible / DeepSeek</option><option value="anthropic-messages">Anthropic Messages</option></select></label>
      <label>Base URL<input value={settings.baseUrl} onChange={(event) => onSettingsChange({ ...settings, baseUrl: event.target.value })} /></label>
      <label>主模型（复杂任务/编码）<input value={settings.model} onChange={(event) => onSettingsChange({ ...settings, model: event.target.value })} /></label>
      <label>快速模型（简单问答/分类，可留空）<input value={settings.fastModel ?? ""} onChange={(event) => onSettingsChange({ ...settings, fastModel: event.target.value })} placeholder="留空则全部使用主模型" /></label>
      <label>API Key<input type="password" value={settings.apiKey} onChange={(event) => onSettingsChange({ ...settings, apiKey: event.target.value })} placeholder="只写入 macOS Keychain" /></label>
      <label>主题<select value={theme} onChange={(event) => onThemeChange(event.target.value as ThemePreference)}><option value="system">跟随系统</option><option value="light">浅色</option><option value="dark">深色</option></select></label>
      <div className="update-row">
        <button type="button" className="check-update" disabled={update.checking} onClick={() => void checkForUpdate()}><Icon name="refresh" />{update.checking ? "正在检查更新…" : "检查并安装更新"}</button>
        {update.result && <p className={`update-result ${update.result.available ? "available" : ""}`}>{update.result.version ? `v${update.result.version} · ` : ""}{update.result.detail}</p>}
      </div>
      <button className="save" type="button" onClick={onSave}><Icon name="check" />保存配置</button>
    </section>
  </div>
}
