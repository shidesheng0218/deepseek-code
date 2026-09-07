import { useState } from "react"
import type { UsageStats } from "../types"

export function formatTokens(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`
  return String(value)
}

export const STAT_RANGES = [{ key: "all", label: "全部", days: undefined }, { key: "30d", label: "30 天", days: 30 }, { key: "7d", label: "7 天", days: 7 }] as const
export type StatRangeKey = typeof STAT_RANGES[number]["key"]

function Heatmap({ stats }: { stats: UsageStats }) {
  const cells = stats.dailyActivity
  const max = Math.max(1, ...cells)
  const padded = [...cells]
  while (padded.length % 7 !== 0) padded.push(0)
  const weeks: number[][] = []
  for (let index = 0; index < padded.length; index += 7) weeks.push(padded.slice(index, index + 7))
  return <div className="heatmap" role="img" aria-label="活动热力图">
    {weeks.map((week, weekIndex) => <div className="heatmap-week" key={weekIndex}>{week.map((count, dayIndex) => {
      const level = count === 0 ? 0 : Math.min(4, 1 + Math.floor((count / max) * 3.999))
      return <i key={dayIndex} className={`heatmap-cell level-${level}`} title={`${count} 个事件`} />
    })}</div>)}
  </div>
}

export function StatsPanel({ stats, range, onRangeChange }: { stats: UsageStats | null; range: StatRangeKey; onRangeChange: (next: StatRangeKey) => void }) {
  const [tab, setTab] = useState<"overview" | "models">("overview")
  if (!stats) return <p className="stats-empty">暂无用量数据，完成第一个任务后开始统计。</p>
  const cards: { label: string; value: string }[] = [
    { label: "会话", value: String(stats.sessions) },
    { label: "消息", value: stats.messages.toLocaleString() },
    { label: "总 Token", value: formatTokens(stats.totalTokens) },
    { label: "活跃天数", value: String(stats.activeDays) },
    { label: "当前连续", value: stats.currentStreak > 0 ? `${stats.currentStreak} 天` : "—" },
    { label: "最长连续", value: stats.longestStreak > 0 ? `${stats.longestStreak} 天` : "—" },
    { label: "高峰时段", value: stats.peakHour !== null ? `${stats.peakHour}:00` : "—" },
    { label: "常用模型", value: stats.favoriteModel ?? "—" },
    // 成本按运行时记录的刊例价估算；未知模型不计入，因此显示的是下限而非精确账单。
    { label: "估算成本", value: stats.estimatedCost > 0 ? `$${stats.estimatedCost < 0.01 ? stats.estimatedCost.toFixed(4) : stats.estimatedCost.toFixed(2)}` : "—" },
  ]
  const maxModelTokens = Math.max(1, ...stats.modelTokens.map((row) => row.tokens))
  const books = Math.floor(stats.totalTokens / 1_000_000)
  return <section className="stats-card">
    <header className="stats-header">
      <nav className="stats-tabs">
        <button type="button" className={tab === "overview" ? "active" : ""} onClick={() => setTab("overview")}>概览</button>
        <button type="button" className={tab === "models" ? "active" : ""} onClick={() => setTab("models")}>模型</button>
      </nav>
      <nav className="stats-ranges">{STAT_RANGES.map((item) => <button key={item.key} type="button" className={range === item.key ? "active" : ""} onClick={() => onRangeChange(item.key)}>{item.label}</button>)}</nav>
    </header>
    {tab === "overview" && <>
      <div className="stats-overview">
        <div className="stats-grid">{cards.map((card) => <div className="stat-card" key={card.label}><span>{card.label}</span><strong>{card.value}</strong></div>)}</div>
        <div className="heatmap-panel">
          <span className="heatmap-title">近 140 天活动</span>
          <Heatmap stats={stats} />
        </div>
      </div>
      <p className="stats-fun">{books >= 1 ? `你的累计 Token 用量已超过 ${books} 本《红楼梦》。` : stats.totalTokens > 0 ? `累计 ${formatTokens(stats.totalTokens)} Token——再努力一点就赶上一本《红楼梦》了。` : "还没有 Token 记录，从第一个任务开始积累。"}</p>
    </>}
    {tab === "models" && <div className="model-rows">
      {stats.modelTokens.length === 0 && <p className="stats-fun">暂无模型用量数据。</p>}
      {stats.modelTokens.map((row) => <div className="model-row" key={row.model}><span className="model-name" title={row.model}>{row.model}</span><div className="model-bar"><i style={{ width: `${Math.max(2, (row.tokens / maxModelTokens) * 100)}%` }} /></div><span className="model-tokens">{formatTokens(row.tokens)}</span></div>)}
    </div>}
  </section>
}
