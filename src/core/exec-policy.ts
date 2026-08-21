/**
 * Exec Policy Engine（改编自 OpenAI Codex execpolicy）
 *
 * Phase 5 提前实现：声明式命令执行策略 + 污点追踪扩展
 *
 * Codex 原版设计：
 * - PrefixRule：匹配命令前缀（"npm test" / "git commit"）
 * - NetworkRule：匹配域名 + 协议
 * - Decision：Allow / Forbidden / Prompt
 *
 * 我们的扩展：
 * - TaintLabel：标记不可信输入来源（prompt_injection / external_api / user_input）
 * - TaintedDecision：Allow / AllowTainted / Prompt / Forbidden
 * - 数据流策略：参数包含污点时升级决策
 */

export type Decision = 'allow' | 'prompt' | 'forbidden';
export type TaintLabel = 'prompt_injection' | 'external_api' | 'user_input' | 'clean';

export interface PrefixRule {
  pattern: string[]; // ["npm", "test"] 匹配 "npm test ..."
  decision: Decision;
  justification?: string;
}

export interface NetworkRule {
  host: string; // "example.com" 或 "*.github.com"
  protocol?: 'http' | 'https' | '*';
  decision: Decision;
  justification?: string;
}

export interface TaintPolicy {
  // 污点升级规则：参数包含指定污点时，决策升级
  upgrades: Array<{
    fromLabel: TaintLabel;
    fromDecision: Decision;
    toDecision: Decision;
  }>;
}

export interface Policy {
  prefixRules: PrefixRule[];
  networkRules: NetworkRule[];
  taintPolicy?: TaintPolicy;
}

export interface EvaluationResult {
  decision: Decision;
  matchedRules: Array<{ type: 'prefix' | 'network'; rule: PrefixRule | NetworkRule }>;
  taintUpgraded: boolean;
  justification?: string;
}

export class PolicyEngine {
  constructor(private readonly policy: Policy) {}

  /**
   * 评估命令是否允许执行（Codex check() 的 TS 移植）
   */
  checkCommand(command: string[], taints: TaintLabel[] = []): EvaluationResult {
    const matchedRules: Array<{ type: 'prefix' | 'network'; rule: PrefixRule | NetworkRule }> = [];
    let decision: Decision = 'prompt'; // 默认需要审批

    // 1. 前缀匹配（Codex PrefixRule）
    for (const rule of this.policy.prefixRules) {
      if (this.matchesPrefix(command, rule.pattern)) {
        matchedRules.push({ type: 'prefix', rule });
        decision = this.maxDecision(decision, rule.decision);
      }
    }

    // 2. 网络规则（如果命令包含 URL）
    const urls = this.extractUrls(command);
    for (const url of urls) {
      for (const rule of this.policy.networkRules) {
        if (this.matchesNetwork(url, rule)) {
          matchedRules.push({ type: 'network', rule });
          decision = this.maxDecision(decision, rule.decision);
        }
      }
    }

    // 3. 污点升级（我们的扩展）
    let taintUpgraded = false;
    if (this.policy.taintPolicy && taints.length > 0) {
      for (const upgrade of this.policy.taintPolicy.upgrades) {
        if (taints.includes(upgrade.fromLabel) && decision === upgrade.fromDecision) {
          decision = upgrade.toDecision;
          taintUpgraded = true;
        }
      }
    }

    const justification = matchedRules
      .map((m) => m.rule.justification)
      .filter(Boolean)
      .join('; ');

    return { decision, matchedRules, taintUpgraded, justification };
  }

  /**
   * 批量评估（Codex check_multiple() 的 TS 移植）
   */
  checkMultiple(commands: Array<{ command: string[]; taints?: TaintLabel[] }>): EvaluationResult[] {
    return commands.map(({ command, taints }) => this.checkCommand(command, taints ?? []));
  }

  /**
   * 合并策略（Codex merge_overlay() 的 TS 移植）
   * overlay 规则优先级更高
   */
  static merge(base: Policy, overlay: Policy): Policy {
    const merged: Policy = {
      prefixRules: [...base.prefixRules, ...overlay.prefixRules],
      networkRules: [...base.networkRules, ...overlay.networkRules]
    };
    if (overlay.taintPolicy) {
      merged.taintPolicy = overlay.taintPolicy;
    } else if (base.taintPolicy) {
      merged.taintPolicy = base.taintPolicy;
    }
    return merged;
  }

  private matchesPrefix(command: string[], pattern: string[]): boolean {
    if (pattern.length > command.length) return false;
    for (let i = 0; i < pattern.length; i++) {
      if (pattern[i] !== '*' && pattern[i] !== command[i]) return false;
    }
    return true;
  }

  private matchesNetwork(url: string, rule: NetworkRule): boolean {
    try {
      const parsed = new URL(url);
      const hostMatch = rule.host === '*' || parsed.hostname === rule.host || (rule.host.startsWith('*.') && parsed.hostname.endsWith(rule.host.slice(1)));
      const protocolMatch = !rule.protocol || rule.protocol === '*' || parsed.protocol.startsWith(rule.protocol);
      return hostMatch && protocolMatch;
    } catch {
      return false;
    }
  }

  private extractUrls(command: string[]): string[] {
    const urlPattern = /https?:\/\/[^\s]+/g;
    return command.flatMap((arg) => arg.match(urlPattern) ?? []);
  }

  private maxDecision(a: Decision, b: Decision): Decision {
    const order: Record<Decision, number> = { allow: 0, prompt: 1, forbidden: 2 };
    return order[a] > order[b] ? a : b;
  }
}

/**
 * 默认策略（兼容 Codex 的常见白名单）
 */
export const defaultPolicy: Policy = {
  prefixRules: [
    { pattern: ['npm', 'test'], decision: 'allow', justification: 'Safe test command' },
    { pattern: ['npm', 'run', 'test'], decision: 'allow' },
    { pattern: ['npm', 'run', 'build'], decision: 'allow' },
    { pattern: ['npm', 'run', 'lint'], decision: 'allow' },
    { pattern: ['git', 'status'], decision: 'allow' },
    { pattern: ['git', 'diff'], decision: 'allow' },
    { pattern: ['git', 'log'], decision: 'allow' },
    { pattern: ['git', 'commit'], decision: 'prompt', justification: 'Commit requires approval' },
    { pattern: ['git', 'push'], decision: 'prompt', justification: 'Push requires approval' },
    { pattern: ['rm', '-rf'], decision: 'forbidden', justification: 'Destructive operation blocked' },
    { pattern: ['curl', '*'], decision: 'prompt', justification: 'Network access requires approval' }
  ],
  networkRules: [
    { host: '*.github.com', decision: 'allow', justification: 'GitHub API allowed' },
    { host: 'api.openai.com', decision: 'allow' },
    { host: '*', decision: 'prompt', justification: 'Unknown domain requires approval' }
  ],
  taintPolicy: {
    upgrades: [
      { fromLabel: 'prompt_injection', fromDecision: 'allow', toDecision: 'forbidden' },
      { fromLabel: 'prompt_injection', fromDecision: 'prompt', toDecision: 'forbidden' },
      { fromLabel: 'external_api', fromDecision: 'allow', toDecision: 'prompt' }
    ]
  }
};
