import type { Approval } from "../types"
import { Icon } from "./Icon"

export function ApprovalCard({ approval, onResolve }: { approval: Approval; onResolve: (decision: "allow" | "deny") => void }) {
  return <section className="approval">
    <header><strong>需要确认</strong><span className={`risk-badge risk-${approval.risk.toLowerCase()}`}>{approval.risk}</span></header>
    <span>{approval.tool} 将执行受控操作。</span>
    {approval.preview && <code className="approval-preview">{approval.preview}</code>}
    <div>
      <button type="button" onClick={() => onResolve("deny")}><Icon name="x" />取消</button>
      <button className="allow" type="button" onClick={() => onResolve("allow")}><Icon name="check" />允许一次</button>
    </div>
  </section>
}
