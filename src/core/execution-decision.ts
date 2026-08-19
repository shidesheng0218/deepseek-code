import { classifyTask, type TaskRoute } from './task-router';

/**
 * Decide 阶段：为一次任务生成确定性的执行决策。
 * 它决定模型层级、允许的工具方向、响应契约与验证要求；
 * 不改变权限系统，只约束“这次任务该怎么走”。
 */

export type ResponseContract =
  | 'direct'      // 直接结论，不超过 3 段
  | 'change'      // 根因/变更文件/测试/风险
  | 'research'    // 结论/Citation/冲突/适用范围
  | 'review'      // 严重级别/位置/证据/建议
  | 'delivery';   // Diff/测试/Commit/PR/CI/未完成项

export interface ExecutionDecision {
  route: TaskRoute;
  modelTier: 'fast' | 'capable';
  responseContract: ResponseContract;
  /** 需要哪些验证证据才能进入 delivered */
  requiredEvidence: Array<'tests' | 'browser' | 'citation' | 'ci'>;
  /** 这次任务允许的工具方向（白名单提示，不替代权限系统） */
  allowWeb: boolean;
  allowWrite: boolean;
  allowCI: boolean;
}

export function decideExecution(input: string): ExecutionDecision {
  const classification = classifyTask(input);
  const route = classification.route;
  switch (route) {
    case 'direct_answer':
      return { route, modelTier: 'fast', responseContract: 'direct', requiredEvidence: [], allowWeb: false, allowWrite: false, allowCI: false };
    case 'project_question':
    case 'exploration':
      return { route, modelTier: 'capable', responseContract: 'direct', requiredEvidence: [], allowWeb: false, allowWrite: false, allowCI: false };
    case 'web_research':
      return { route, modelTier: 'capable', responseContract: 'research', requiredEvidence: ['citation'], allowWeb: true, allowWrite: false, allowCI: false };
    case 'code_change':
    case 'browser_fix':
      return { route, modelTier: 'capable', responseContract: 'change', requiredEvidence: route === 'browser_fix' ? ['tests', 'browser'] : ['tests'], allowWeb: false, allowWrite: true, allowCI: false };
    case 'review':
      return { route, modelTier: 'capable', responseContract: 'review', requiredEvidence: [], allowWeb: false, allowWrite: false, allowCI: false };
    case 'ci_repair':
      return { route, modelTier: 'capable', responseContract: 'delivery', requiredEvidence: ['tests', 'ci'], allowWeb: false, allowWrite: true, allowCI: true };
    case 'delivery':
    default:
      return { route, modelTier: 'capable', responseContract: 'delivery', requiredEvidence: ['tests'], allowWeb: false, allowWrite: true, allowCI: true };
  }
}

/** 把决策转成注入 system 指令的行为约束，保持输出自然、结构稳定 */
export function decisionInstructions(decision: ExecutionDecision): string {
  if (decision.route === 'direct_answer') {
    return '这是一个简单问题。直接给出自然、准确的结论，不超过 3 段；不要调用工具，不要生成计划，不要暴露内部判断。';
  }
  const lines: string[] = [];
  if (decision.responseContract === 'change') lines.push('完成后说明：根因、修改了哪些文件、测试/验证结果、剩余风险。');
  if (decision.responseContract === 'research') lines.push('完成后说明：结论、每条结论的引用来源、来源之间的冲突、适用范围。');
  if (decision.responseContract === 'review') lines.push('按严重级别列出发现：位置、证据、建议；不要直接修改文件。');
  if (decision.responseContract === 'delivery') lines.push('交付前确认 Diff、测试、相关 CI/Browser 状态；说明未完成项。');
  if (decision.requiredEvidence.includes('tests')) lines.push('修改代码后运行相关测试或构建来验证。');
  if (!decision.allowWeb) lines.push('不要联网；使用本地项目信息回答。');
  lines.push('不要在对话中暴露路由、Token、策略或工具 JSON 等内部细节。');
  return lines.join('');
}
