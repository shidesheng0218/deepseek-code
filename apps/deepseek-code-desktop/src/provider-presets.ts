import type { Settings } from "./types"

/**
 * 服务商预设：选中后一次性填好 Base URL + 协议 + 建议模型名，
 * 用户仍可在填完后手动改任意字段——这只是免去"记不住 URL"的负担，
 * 不是把设置锁死成几个选项。
 *
 * "自定义" 永远排第一且不改变任何已填字段，用于用户已经手填过配置、
 * 或者用的是这里没收录的服务商时保持现状。
 */
export interface ProviderPreset {
  id: string
  label: string
  baseUrl: string
  protocol: Settings["protocol"]
  /** 选中后建议填入的模型名；用户可继续手动改。 */
  suggestedModel: string
  suggestedFastModel?: string
}

export const PROVIDER_PRESETS: ProviderPreset[] = [
  {
    id: "custom",
    label: "自定义",
    baseUrl: "",
    protocol: "openai-compatible",
    suggestedModel: ""
  },
  {
    id: "deepseek",
    label: "DeepSeek 官方",
    baseUrl: "https://api.deepseek.com/v1",
    protocol: "openai-compatible",
    suggestedModel: "deepseek-v4-flash"
  },
  {
    id: "bailian",
    label: "阿里云百炼（DashScope）",
    baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    protocol: "openai-compatible",
    suggestedModel: "qwen-plus",
    suggestedFastModel: "qwen-turbo"
  },
  {
    id: "anthropic",
    label: "Anthropic 官方",
    baseUrl: "https://api.anthropic.com/v1",
    protocol: "anthropic-messages",
    suggestedModel: "claude-sonnet-5"
  }
]

/** 按当前 baseUrl 反推匹配的预设 id；找不到匹配（用户手填了未收录的服务商）时返回 "custom"。 */
export function presetIdForBaseUrl(baseUrl: string): string {
  const trimmed = baseUrl.trim().replace(/\/+$/, "")
  const match = PROVIDER_PRESETS.find((preset) => preset.id !== "custom" && preset.baseUrl.replace(/\/+$/, "") === trimmed)
  return match?.id ?? "custom"
}

export function applyProviderPreset(settings: Settings, presetId: string): Settings {
  const preset = PROVIDER_PRESETS.find((item) => item.id === presetId)
  if (!preset || preset.id === "custom") return settings
  return {
    ...settings,
    baseUrl: preset.baseUrl,
    protocol: preset.protocol,
    model: preset.suggestedModel,
    ...(preset.suggestedFastModel !== undefined ? { fastModel: preset.suggestedFastModel } : {})
  }
}
