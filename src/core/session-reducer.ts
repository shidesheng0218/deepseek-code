export type SessionStatus = 'idle' | 'planning' | 'running' | 'waiting_approval' | 'completed' | 'failed' | 'cancelled';

export interface PlanStep {
  id: string;
  title: string;
  status: 'pending' | 'active' | 'completed' | 'blocked';
}

export interface SessionState {
  id: string;
  status: SessionStatus;
  plan: PlanStep[];
  pendingApproval?: { id: string; tool: string; risk: string };
  usage: { inputTokens: number; cachedInputTokens: number; outputTokens: number; estimatedCost: number };
}

export type SessionEvent =
  | { type: 'session_status_changed'; status: SessionStatus }
  | { type: 'plan_updated'; steps: PlanStep[] }
  | { type: 'approval_requested'; approvalId: string; tool: string; risk: string }
  | { type: 'approval_resolved'; approvalId: string; decision: 'allow' | 'deny' }
  | { type: 'usage_recorded'; inputTokens: number; cachedInputTokens: number; outputTokens: number; estimatedCost: number };

export function createSessionState(id: string): SessionState {
  return { id, status: 'idle', plan: [], usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, estimatedCost: 0 } };
}

export function reduceSessionEvents(state: SessionState, events: SessionEvent[]): SessionState {
  return events.reduce<SessionState>((current, event) => {
    switch (event.type) {
      case 'session_status_changed':
        return { ...current, status: event.status };
      case 'plan_updated':
        return { ...current, plan: event.steps.map((step) => ({ ...step })) };
      case 'approval_requested':
        return {
          ...current,
          status: 'waiting_approval',
          pendingApproval: { id: event.approvalId, tool: event.tool, risk: event.risk }
        };
      case 'approval_resolved': {
        if (current.pendingApproval?.id !== event.approvalId) return current;
        return {
          id: current.id,
          status: event.decision === 'allow' ? 'running' : 'planning',
          plan: current.plan,
          usage: current.usage
        };
      }
      case 'usage_recorded':
        return {
          ...current,
          usage: {
            inputTokens: current.usage.inputTokens + event.inputTokens,
            cachedInputTokens: current.usage.cachedInputTokens + event.cachedInputTokens,
            outputTokens: current.usage.outputTokens + event.outputTokens,
            estimatedCost: Number((current.usage.estimatedCost + event.estimatedCost).toFixed(6))
          }
        };
    }
  }, state);
}
