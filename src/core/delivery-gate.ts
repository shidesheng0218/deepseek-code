export interface DeliveryEvent { type: string; payload?: Record<string, unknown> }
export type DeliveryState = 'delivered' | 'handoffReady' | 'needsRepair' | 'needsAttention';

export function evaluateDeliveryGate(events: DeliveryEvent[]): { state: DeliveryState; reasons: string[] } {
  const resolved = new Set(events.filter((event) => event.type === 'approval_resolved' && typeof event.payload?.approvalID === 'string').map((event) => event.payload?.approvalID as string));
  const pending = events.filter((event) => event.type === 'approval_pending' && typeof event.payload?.approvalID === 'string' && !resolved.has(event.payload?.approvalID as string));
  if (pending.length) return { state: 'needsAttention', reasons: ['存在未解决审批。'] };
  if (events.some((event) => event.type === 'tool_indeterminate')) return { state: 'needsAttention', reasons: ['存在结果未知的副作用。'] };
  const completedToolIDs = new Set(events.filter((event) => (event.type === 'tool_completed' || event.type === 'tool_failed') && typeof event.payload?.id === 'string').map((event) => event.payload?.id as string));
  const incompleteTool = events.find((event) => event.type === 'tool_started' && typeof event.payload?.id === 'string' && !completedToolIDs.has(event.payload?.id as string));
  if (incompleteTool) return { state: 'needsAttention', reasons: ['存在开始后未确认结果的工具调用。'] };
  const ciState = events.reduce<'unknown' | 'failed' | 'passed'>((state, event) => {
    if (event.type === 'ci_failure_classified') return 'failed';
    if (event.type === 'ci_status' && event.payload?.passed === true) return 'passed';
    return state;
  }, 'unknown');
  if (ciState === 'failed') return { state: 'needsRepair', reasons: ['当前 Commit 的 GitHub Actions 仍存在失败。'] };
  if (events.some((event) => event.type === 'terminal_completed' && event.payload?.exitCode !== 0)) return { state: 'needsRepair', reasons: ['存在失败的终端验证。'] };
  if (events.some((event) => event.type === 'tool_failed' || event.type === 'tool_completed' && event.payload?.ok === false)) return { state: 'needsRepair', reasons: ['存在失败的工具调用。'] };
  if (events.some((event) => event.type === 'verification_passed')) return { state: 'delivered', reasons: [] };
  return { state: 'handoffReady', reasons: ['尚无明确验证通过证据。'] };
}
