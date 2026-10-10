import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"
import { appendAssistantStream, reconcileFinalAssistantResponse, type Message } from "./conversation-grouping"

const stylesSource = readFileSync(new URL("./styles.css", import.meta.url), "utf8")

describe("conversation response rendering", () => {
  it("replaces the streaming answer even when a delivery status arrives in between", () => {
    const messages: Message[] = [
      { role: "user", text: "你能做什么" },
      { role: "assistant", text: "我可以帮你完成以下工作。", kind: "stream" },
      { role: "tool", text: "交付门禁：待交接", kind: "delivery_evaluated" },
    ]

    expect(reconcileFinalAssistantResponse(messages, "我可以帮你完成以下工作。")).toEqual([
      { role: "user", text: "你能做什么" },
      { role: "assistant", text: "我可以帮你完成以下工作。" },
      { role: "tool", text: "交付门禁：待交接", kind: "delivery_evaluated" },
    ])
  })

  it("does not append an already-rendered final response", () => {
    const messages: Message[] = [
      { role: "user", text: "你好" },
      { role: "assistant", text: "你好，有什么可以帮你？" },
      { role: "tool", text: "交付门禁：待交接", kind: "delivery_evaluated" },
    ]

    expect(reconcileFinalAssistantResponse(messages, "你好，有什么可以帮你？")).toEqual(messages)
  })

  it("ignores a late streaming fragment after the final response arrived first", () => {
    const messages: Message[] = [
      { role: "user", text: "你好" },
      { role: "assistant", text: "最终回答" },
      { role: "tool", text: "交付门禁：待交接", kind: "delivery_evaluated" },
    ]

    expect(appendAssistantStream(messages, "迟到的片段")).toEqual(messages)
  })

  it("keeps the composer in a bottom-pinned flex layout while messages scroll", () => {
    expect(stylesSource).toMatch(/\.workspace\s*\{[^}]*display:\s*flex/)
    expect(stylesSource).toMatch(/\.composer\s*\{[^}]*position:\s*sticky/)
    expect(stylesSource).toMatch(/\.conversation\s*\{[^}]*min-height:\s*0/)
    expect(stylesSource).not.toContain(".composer { position: relative; }")
  })
})
