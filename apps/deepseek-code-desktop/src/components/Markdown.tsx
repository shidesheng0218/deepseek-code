import { isValidElement, memo, useDeferredValue, useState, type ReactNode } from "react"
import ReactMarkdown from "react-markdown"
import remarkGfm from "remark-gfm"
import rehypeHighlight from "rehype-highlight"

function extractText(node: ReactNode): string {
  if (node == null || typeof node === "boolean") return ""
  if (typeof node === "string" || typeof node === "number") return String(node)
  if (Array.isArray(node)) return node.map(extractText).join("")
  if (isValidElement(node)) return extractText((node.props as { children?: ReactNode }).children)
  return ""
}

async function copyText(text: string): Promise<boolean> {
  try { await navigator.clipboard.writeText(text); return true } catch { /* fall through to execCommand */ }
  try {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    const ok = document.execCommand("copy")
    textarea.remove()
    return ok
  } catch { return false }
}

function CodeBlock({ children }: { children?: ReactNode }) {
  const [copied, setCopied] = useState(false)
  const code = extractText(children)
  return <div className="codeblock">
    <button
      type="button"
      className="codeblock-copy"
      onClick={() => void copyText(code).then((ok) => { if (ok) { setCopied(true); setTimeout(() => setCopied(false), 1600) } })}
    >{copied ? "已复制" : "复制"}</button>
    <pre>{children}</pre>
  </div>
}

/**
 * 助手消息的 Markdown 渲染。流式期间用 useDeferredValue 滞后一拍解析，
 * 避免每个 token 帧都全量解析拖慢输入与动画；非流式消息直接渲染。
 * 链接不跳转（Tauri webview 内导航既不安全也无意义），以文本+title 呈现 URL。
 */
export const Markdown = memo(function Markdown({ text, streaming }: { text: string; streaming?: boolean }) {
  // useDeferredValue 必须无条件调用——同一元素若在流式/非流式间切换
  // streaming 却条件调用它，会导致相邻渲染间 Hook 数量不一致。
  // 非流式时用原始 text 而不是 deferredText，效果等同（无需滞后）。
  const deferredText = useDeferredValue(text)
  const deferred = streaming ? deferredText : text
  return <div className="markdown">
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      rehypePlugins={[[rehypeHighlight, { detect: false, ignoreMissing: true }]]}
      components={{
        pre: ({ children }) => <CodeBlock>{children}</CodeBlock>,
        a: ({ href, children }) => <span className="md-link" title={href}>{children}</span>,
      }}
    >{deferred}</ReactMarkdown>
  </div>
})
