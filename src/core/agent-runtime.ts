import { classifyToolRequest, decidePermission, type AgentMode, type PermissionDecision, type RiskLevel } from './permissions';

export interface RuntimeToolRequest {
  id: string;
  tool: string;
  command?: string;
  mutates: boolean;
}

export interface RuntimeState {
  status: 'planning' | 'running' | 'waiting_approval' | 'completed';
}

export type RuntimeEvent =
  | { type: 'tool_requested'; id: string; tool: string; risk: RiskLevel }
  | { type: 'approval_requested'; id: string; tool: string; risk: RiskLevel }
  | { type: 'approval_resolved'; id: string; decision: 'allow' | 'deny' }
  | { type: 'tool_blocked'; id: string; tool: string; risk: RiskLevel };

export class AgentRuntime {
  readonly state: RuntimeState = { status: 'planning' };
  readonly events: RuntimeEvent[] = [];
  private pendingApprovalId: string | undefined;

  constructor(private readonly options: { sessionId: string; mode: AgentMode }) {}

  requestTool(request: RuntimeToolRequest): { decision: PermissionDecision; risk: RiskLevel } {
    const classificationInput = request.command === undefined ? { tool: request.tool } : { tool: request.tool, command: request.command };
    const risk = classifyToolRequest(classificationInput).risk;
    const decision = decidePermission({ mode: this.options.mode, risk, mutates: request.mutates, tool: request.tool });
    if (decision === 'allow') {
      this.state.status = 'running';
      this.events.push({ type: 'tool_requested', id: request.id, tool: request.tool, risk });
    } else if (decision === 'ask') {
      this.pendingApprovalId = request.id;
      this.state.status = 'waiting_approval';
      this.events.push({ type: 'approval_requested', id: request.id, tool: request.tool, risk });
    } else {
      this.events.push({ type: 'tool_blocked', id: request.id, tool: request.tool, risk });
    }
    return { decision, risk };
  }

  resolveApproval(approvalId: string, decision: 'allow' | 'deny'): void {
    if (this.pendingApprovalId !== approvalId) return;
    this.events.push({ type: 'approval_resolved', id: approvalId, decision });
    this.pendingApprovalId = undefined;
    this.state.status = decision === 'allow' ? 'running' : 'planning';
  }

  complete(): void {
    this.state.status = 'completed';
  }
}
