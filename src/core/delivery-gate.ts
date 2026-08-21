export interface DeliveryEvent { type: string; payload?: Record<string, unknown> }
export type DeliveryState = 'delivered' | 'handoffReady' | 'needsRepair' | 'needsAttention';

/**
 * 交付门禁 v2（NEXT_GEN_ARCHITECTURE Phase 1）。
 *
 * v2 新增规则：delivered 要求 verifier_verdict(state=pass) 且 receipt_issued。
 * 旧会话（无 verifier_verdict 事件）按 v1 规则兼容评估。
 */
export function evaluateDeliveryGate(events: DeliveryEvent[]): { state: DeliveryState; reasons: string[] } {
  const resolved = new Set(events.filter((event) => event.type === 'approval_resolved' && typeof event.payload?.approvalID === 'string').map((event) => event.payload?.approvalID as string));
  const pending = events.filter((event) => event.type === 'approval_pending' && typeof event.payload?.approvalID === 'string' && !resolved.has(event.payload?.approvalID as string));
  if (pending.length) return { state: 'needsAttention', reasons: ['存在未解决审批。'] };
  if (events.some((event) => event.type === 'tool_indeterminate')) return { state: 'needsAttention', reasons: ['存在结果未知的副作用。'] };
  const pendingPRUpdates = events.filter((event) => event.type === 'ci_repair_pr_update_ready' && typeof event.payload?.number === 'number').filter((event) => {
    const number = event.payload?.number as number;
    return !events.some((candidate) => candidate.type === 'github_pr_updated' && candidate.payload?.number === number);
  });
  if (pendingPRUpdates.length) return { state: 'needsAttention', reasons: ['CI 修复结果尚未回写原始 Pull Request。'] };
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

  // Gate v2：delivered 要求 verifier_verdict(pass) 且 receipt_issued（v1 兼容：无 verifier_verdict 时按旧规则）
  const verifierVerdicts = events.filter((event) => event.type === 'verifier_verdict');
  if (verifierVerdicts.length > 0) {
    const latestVerdict = verifierVerdicts[verifierVerdicts.length - 1];
    if (!latestVerdict) return { state: 'handoffReady', reasons: ['Verifier 裁决缺失。'] };
    const verdictState = latestVerdict.payload?.state as string | undefined;
    if (verdictState === 'refuted') return { state: 'needsRepair', reasons: ['Verifier 反驳了交付声明。'] };
    if (verdictState === 'inconclusive') return { state: 'handoffReady', reasons: ['Verifier 无法给出明确裁决。'] };
    if (verdictState === 'pass') {
      const hasReceipt = events.some((event) => event.type === 'receipt_issued');
      if (hasReceipt) return { state: 'delivered', reasons: [] };
      return { state: 'handoffReady', reasons: ['Verifier 通过但回执尚未签发。'] };
    }
  }

  // v1 兼容路径：无 verifier_verdict 时，verification_passed 足够
  if (events.some((event) => event.type === 'verification_passed')) return { state: 'delivered', reasons: [] };
  return { state: 'handoffReady', reasons: ['尚无明确验证通过证据。'] };
}
