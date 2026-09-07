import { listen } from "@tauri-apps/api/event"
import type { RuntimeFrame } from "./types"

/**
 * 等待某个请求 id 对应的 response 帧。终端命令、skills.list 这类请求-响应式调用
 * 不能复用会话消息流"下一条 response 就是它"的逻辑（可能并发多条），
 * 统一按 frame.id 过滤。
 */
export function waitForFrame(requestID: string, timeoutMs = 120_000): Promise<RuntimeFrame> {
  return new Promise((resolve, reject) => {
    let unlisten: (() => void) | undefined
    const timer = setTimeout(() => { unlisten?.(); reject(new Error("请求超时")) }, timeoutMs)
    void listen<RuntimeFrame>("runtime-event", (event) => {
      if (event.payload.id !== requestID) return
      clearTimeout(timer)
      unlisten?.()
      resolve(event.payload)
    }).then((stop) => { unlisten = stop })
  })
}
