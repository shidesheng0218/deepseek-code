export function QuickIcon({ name }: { name: string }) {
  const common = { fill: "none", stroke: "currentColor", strokeWidth: 1.4, strokeLinecap: "round", strokeLinejoin: "round" } as const
  if (name === "bug") return <svg viewBox="0 0 16 16" {...common}><circle cx="8" cy="9.5" r="3.4" /><path d="M6 6.6 4.9 4.8M10 6.6l1.1-1.8M4.6 9H2.2M4.9 11.4l-1.7 1.4M11.4 9h2.4M11.1 11.4l1.7 1.4" /></svg>
  if (name === "code") return <svg viewBox="0 0 16 16" {...common}><path d="M5.5 4.5 2 8l3.5 3.5M10.5 4.5 14 8l-3.5 3.5" /></svg>
  if (name === "globe") return <svg viewBox="0 0 16 16" {...common}><circle cx="8" cy="8" r="5.8" /><ellipse cx="8" cy="8" rx="2.5" ry="5.8" /><path d="M2.2 8h11.6" /></svg>
  return <svg viewBox="0 0 16 16" {...common}><circle cx="8" cy="8" r="5.8" /><path d="M6.6 5.4 11 8l-4.4 2.6z" fill="currentColor" stroke="none" /></svg>
}

/** 通用线性图标，风格与 QuickIcon 一致（同样的描边粗细、圆角端点），
 *  用在侧边栏导航、审批操作、发送/停止等功能按钮上，减少纯文字带来的扁平感。 */
export function Icon({ name, className }: { name: string; className?: string }) {
  const common = { fill: "none", stroke: "currentColor", strokeWidth: 1.4, strokeLinecap: "round", strokeLinejoin: "round" } as const
  const props = { viewBox: "0 0 16 16", className: `icon ${className ?? ""}`.trim(), "aria-hidden": true } as const
  if (name === "plus") return <svg {...props} {...common}><path d="M8 3v10M3 8h10" /></svg>
  if (name === "chat") return <svg {...props} {...common}><path d="M2.6 8c0-3 2.6-5 5.4-5s5.4 2 5.4 5c0 2.9-2.6 5.3-5.4 5.3-.7 0-1.4-.1-2-.3-.8.4-1.6.7-2.5.8.5-.6.8-1.3.9-2.1C2.4 10.4 2.6 9 2.6 8Z" /></svg>
  if (name === "settings") return <svg {...props} {...common}><path d="M2.5 4h5.3M10.3 4h3.2M2.5 8h2.7M7.7 8h5.8M2.5 12h6.6M11.6 12h1.9" /><circle cx="8.7" cy="4" r="1.3" fill="currentColor" stroke="none" /><circle cx="5.9" cy="8" r="1.3" fill="currentColor" stroke="none" /><circle cx="10" cy="12" r="1.3" fill="currentColor" stroke="none" /></svg>
  if (name === "terminal") return <svg {...props} {...common}><rect x="2" y="3.2" width="12" height="9.6" rx="1.4" /><path d="M4.6 6.4 6.9 8l-2.3 1.6M8.2 10.4h3.2" /></svg>
  if (name === "chart") return <svg {...props} {...common}><path d="M2.6 13.2V8.4M7.1 13.2V2.8M11.6 13.2V6M2 13.2h12" /></svg>
  if (name === "folder") return <svg {...props} {...common}><path d="M2.2 4.8a.7.7 0 0 1 .7-.7h3.2l1.2 1.6h5.8a.7.7 0 0 1 .7.7v5.6a.7.7 0 0 1-.7-.7H2.9a.7.7 0 0 1-.7-.7Z" /></svg>
  if (name === "check") return <svg {...props} {...common}><path d="M3.5 8.4 6.4 11.3 12.5 4.7" /></svg>
  if (name === "x") return <svg {...props} {...common}><path d="M4.2 4.2l7.6 7.6M11.8 4.2l-7.6 7.6" /></svg>
  if (name === "send") return <svg {...props} {...common}><path d="M2.4 8 13 3l-4.4 10.6-1.7-4.5z" /><path d="M13 3 6.9 9.1" /></svg>
  if (name === "stop") return <svg {...props} {...common}><rect x="4.6" y="4.6" width="6.8" height="6.8" rx="1.2" fill="currentColor" stroke="none" /></svg>
  if (name === "refresh") return <svg {...props} {...common}><path d="M13.2 8a5.2 5.2 0 1 1-1.5-3.7M13.2 2.6v2.6h-2.6" /></svg>
  return null
}
