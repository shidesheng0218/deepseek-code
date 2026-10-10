import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"

describe("chat usage metadata", () => {
  it("does not render the transient usage bar in the chat workspace", () => {
    const appSource = readFileSync(new URL("./App.tsx", import.meta.url), "utf8")
    expect(appSource).not.toContain('className="usage-bar"')
  })
})
