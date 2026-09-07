import { describe, expect, it } from "vitest"
import { applyProviderPreset, presetIdForBaseUrl, PROVIDER_PRESETS } from "./provider-presets"
import { defaultSettings } from "./types"

describe("presetIdForBaseUrl", () => {
  it("matches a known preset by exact baseUrl", () => {
    expect(presetIdForBaseUrl("https://dashscope.aliyuncs.com/compatible-mode/v1")).toBe("bailian")
  })

  it("ignores a trailing slash difference", () => {
    expect(presetIdForBaseUrl("https://dashscope.aliyuncs.com/compatible-mode/v1/")).toBe("bailian")
  })

  it("falls back to custom for an unrecognized baseUrl", () => {
    expect(presetIdForBaseUrl("https://my-own-proxy.example.com/v1")).toBe("custom")
  })

  it("falls back to custom for an empty baseUrl", () => {
    expect(presetIdForBaseUrl("")).toBe("custom")
  })
})

describe("applyProviderPreset", () => {
  it("fills baseUrl/protocol/model/fastModel for a known preset", () => {
    const result = applyProviderPreset(defaultSettings, "bailian")
    expect(result.baseUrl).toBe("https://dashscope.aliyuncs.com/compatible-mode/v1")
    expect(result.protocol).toBe("openai-compatible")
    expect(result.model).toBe("qwen-plus")
    expect(result.fastModel).toBe("qwen-turbo")
  })

  it("leaves every field untouched when selecting custom", () => {
    const edited = { ...defaultSettings, baseUrl: "https://something-else.example.com", apiKey: "sk-mine", projectPath: "/tmp/proj" }
    expect(applyProviderPreset(edited, "custom")).toEqual(edited)
  })

  it("preserves apiKey and projectPath when switching preset (only connection fields change)", () => {
    const edited = { ...defaultSettings, apiKey: "sk-mine", projectPath: "/tmp/proj" }
    const result = applyProviderPreset(edited, "bailian")
    expect(result.apiKey).toBe("sk-mine")
    expect(result.projectPath).toBe("/tmp/proj")
  })

  it("returns settings unchanged for an unknown preset id", () => {
    expect(applyProviderPreset(defaultSettings, "not-a-real-preset")).toEqual(defaultSettings)
  })

  it("every non-custom preset has a non-empty baseUrl and suggestedModel", () => {
    for (const preset of PROVIDER_PRESETS) {
      if (preset.id === "custom") continue
      expect(preset.baseUrl.length).toBeGreaterThan(0)
      expect(preset.suggestedModel.length).toBeGreaterThan(0)
    }
  })
})
