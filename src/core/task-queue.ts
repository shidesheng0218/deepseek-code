/**
 * Task Queue（NEXT_GEN_ARCHITECTURE 支柱三 §3.2.2）
 *
 * 把 CIRepairQueue 的"延迟到安全边界"泛化为通用工单系统：一个工单可以排队、
 * 等审批、等 CI、等另一个工单完成，状态迁移全部走事件日志，崩溃后可恢复。
 *
 * 这个模块只负责状态机的纯逻辑（哪些工单现在可以进 queued、状态转移是否合法），
 * 不涉及 IPC/子进程/HTTP——那些由 apps/deepseek-agent-runtime/src/main.ts 里的
 * 调度循环负责，复用已有的 queues/drain/activeSessions 执行引擎，本模块只决定
 * "现在该不该把这个工单塞进那套执行引擎"。
 */

export type TaskTicketState =
  | 'queued' | 'running'
  | 'waiting_approval'      // 审批事件到达自动续跑（走已有的 session.resolveApproval 链路）
  | 'waiting_ci'            // 挂起，轮询 github_ci_status 或收 webhook
  | 'waiting_dependency'    // 等另一个工单 done
  | 'done' | 'failed'

export interface TaskTicket {
  ticketID: string
  sessionID: string          // 每个工单一条会话（可 fork）
  prompt: string
  projectPath: string
  state: TaskTicketState
  priority: number
  blockedBy?: string[]       // 依赖图，拓扑调度
  waitingCommit?: string     // state === "waiting_ci" 时，正在等哪个 commit 的 CI 结果
  createdAt: string
  updatedAt: string
  error?: string
}

/** 状态机允许的转移；防止调用方把工单从终态（done/failed）意外推回其他状态。 */
const ALLOWED_TRANSITIONS: Record<TaskTicketState, TaskTicketState[]> = {
  queued: ['running', 'waiting_dependency', 'failed'],
  running: ['done', 'failed', 'waiting_approval', 'waiting_ci'],
  waiting_approval: ['queued', 'failed'],
  waiting_ci: ['queued', 'failed'],
  waiting_dependency: ['queued', 'failed'],
  done: [],
  failed: []
}

export function canTransition(from: TaskTicketState, to: TaskTicketState): boolean {
  return ALLOWED_TRANSITIONS[from].includes(to)
}

export interface TicketStore {
  list(): TaskTicket[]
}

/**
 * 依赖图调度：一个 waiting_dependency 状态的工单，只有它 blockedBy 里列出的
 * 全部工单都到达 done 才能转回 queued。用真实的 store 查询而不是假设调用方
 * 传对了顺序——依赖工单本身可能还没创建、可能失败了（failed 的依赖永远不会
 * 变成 done，这种工单应该被判定为永久阻塞，不是"继续等"）。
 */
export function resolveDependencies(ticket: TaskTicket, store: TicketStore): { ready: boolean; blockedReason?: string } {
  if (!ticket.blockedBy || ticket.blockedBy.length === 0) return { ready: true }
  const all = store.list()
  const byID = new Map(all.map((t) => [t.ticketID, t]))
  for (const depID of ticket.blockedBy) {
    const dep = byID.get(depID)
    if (!dep) return { ready: false, blockedReason: `依赖的工单 ${depID} 不存在` }
    if (dep.state === 'failed') return { ready: false, blockedReason: `依赖的工单 ${depID} 已失败，永久阻塞` }
    if (dep.state !== 'done') return { ready: false, blockedReason: `依赖的工单 ${depID} 尚未完成（当前状态：${dep.state}）` }
  }
  return { ready: true }
}

/** 按优先级（数值越大越先跑）挑出所有当前处于 queued 且依赖已满足的工单。
 *  这是纯函数，调用方负责真正把结果推进执行引擎（main.ts 的 queues/drain）。 */
export function selectRunnable(tickets: TaskTicket[]): TaskTicket[] {
  const store: TicketStore = { list: () => tickets }
  return tickets
    .filter((ticket) => ticket.state === 'queued')
    .filter((ticket) => resolveDependencies(ticket, store).ready)
    .sort((a, b) => b.priority - a.priority)
}

/** waiting_dependency 状态的工单里，哪些现在依赖已满足，应该转回 queued。 */
export function selectDependencyResolved(tickets: TaskTicket[]): TaskTicket[] {
  const store: TicketStore = { list: () => tickets }
  return tickets.filter((ticket) => ticket.state === 'waiting_dependency' && resolveDependencies(ticket, store).ready)
}
