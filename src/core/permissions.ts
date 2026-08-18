export type AgentMode = 'plan' | 'manual' | 'accept_edits' | 'auto';
export type RiskLevel = 'L0' | 'L1' | 'L2' | 'L3' | 'L4';
export type PermissionDecision = 'allow' | 'ask' | 'block';

export interface PermissionRequest {
  mode: AgentMode;
  risk: RiskLevel;
  mutates: boolean;
  tool?: string;
}

export function classifyToolRequest(request: { tool: string; command?: string }): { risk: RiskLevel } {
  if (request.tool.startsWith('mcp__')) return { risk: 'L2' };
  if (request.tool !== 'run_command') {
    if (request.tool === 'apply_patch') return { risk: 'L1' };
    if (request.tool === 'git_action') return { risk: 'L2' };
    return { risk: 'L0' };
  }

  const command = request.command?.trim().toLowerCase() ?? '';
  if (/\bsudo\b|\bmkfs\b|\bdiskutil\s+erase\b|:\s*\(\s*\)\s*\{|\bgit\s+push\s+.*--force\b|\brm\s+-[^\n]*r[^\n]*f\s+(?:\/|~)/.test(command)) {
    return { risk: 'L4' };
  }
  if (/\brm\b|\bchmod\b|\bchown\b|\bmv\b/.test(command)) return { risk: 'L3' };
  if (/\b(?:npm|pnpm|yarn|bun)\s+(?:install|add|remove|update|publish)\b|\b(?:curl|wget)\b|\bgit\s+(?:commit|push|rebase|reset)\b/.test(command)) {
    return { risk: 'L2' };
  }
  if (/\b(?:npm|pnpm|yarn|bun)\s+(?:test|run\s+(?:test|lint|build)|lint|build)\b|\b(?:vitest|pytest|cargo\s+test|go\s+test)\b/.test(command)) {
    return { risk: 'L1' };
  }
  return { risk: 'L0' };
}

export function decidePermission(request: PermissionRequest): PermissionDecision {
  if (request.risk === 'L4') return 'block';
  if (request.mode === 'plan') return request.risk === 'L0' && !request.mutates ? 'allow' : 'block';
  if (!request.mutates && request.risk === 'L0') return 'allow';
  if (request.mode === 'manual') return 'ask';
  if (request.mode === 'accept_edits') {
    return request.tool === 'apply_patch' && request.risk === 'L1' ? 'allow' : 'ask';
  }
  if (request.risk === 'L0' || request.risk === 'L1') return 'allow';
  return request.risk === 'L3' ? 'block' : 'ask';
}
