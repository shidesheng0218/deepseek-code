import type { AgentMessage } from './agent-executor';

/**
 * 上下文工程：控制进入模型的消息体量。
 * 系统规则与最近对话保留；过长的工具输出替换为可追溯摘要。
 * 这是压缩策略，不改变事件日志中的完整证据。
 */

export interface ContextBudget {
  /** 进入模型的总字符预算（近似 token 的保守代理） */
  maxChars: number;
  /** 单条工具输出超过此长度时压缩为摘要 */
  maxToolChars: number;
  /** 保留的最近消息条数 */
  keepRecent: number;
}

export const DEFAULT_CONTEXT_BUDGET: ContextBudget = {
  maxChars: 120_000,
  maxToolChars: 6_000,
  keepRecent: 20
};

function summarizeToolOutput(content: string): string {
  const head = content.slice(0, 1_500);
  const tail = content.slice(-1_000);
  return `${head}\n…[已压缩 ${content.length - 2_500} 字符，完整输出保留在 Evidence]…\n${tail}`;
}

/**
 * 丢弃失去配对的工具消息。预算裁剪可能切断 assistant 的 toolCalls 与对应
 * tool 结果消息，孤儿 tool 消息会被严格 Provider（Moonshot、Anthropic）拒绝。
 * 旧格式历史（没有任何 assistant toolCalls，例如事件日志重建的对话）原样保留。
 */
function dropOrphanToolMessages(messages: AgentMessage[]): AgentMessage[] {
  const declared = new Set<string>();
  const answered = new Set<string>();
  for (const message of messages) {
    if (message.role === 'assistant') for (const call of message.toolCalls ?? []) declared.add(call.id);
    if (message.role === 'tool' && message.toolCallId) answered.add(message.toolCallId);
  }
  if (declared.size === 0) return messages;
  return messages.flatMap((message) => {
    if (message.role === 'tool') return message.toolCallId && declared.has(message.toolCallId) ? [message] : [];
    if (message.role === 'assistant' && message.toolCalls?.length) {
      const calls = message.toolCalls.filter((call) => answered.has(call.id));
      if (calls.length === message.toolCalls.length) return [message];
      if (calls.length === 0) return message.content ? [{ role: 'assistant' as const, content: message.content }] : [];
      return [{ ...message, toolCalls: calls }];
    }
    return [message];
  });
}

export function buildContext(messages: AgentMessage[], budget: ContextBudget = DEFAULT_CONTEXT_BUDGET): AgentMessage[] {
  const system = messages.filter((message) => message.role === 'system');
  const rest = messages.filter((message) => message.role !== 'system');

  // 压缩超长工具输出
  const compacted = rest.map((message) => {
    if (message.role === 'tool' && message.content.length > budget.maxToolChars) {
      return { ...message, content: summarizeToolOutput(message.content) };
    }
    return message;
  });

  // 保留最近对话，丢弃最早的中间轮次
  const recent = compacted.slice(-budget.keepRecent);

  let total = system.reduce((sum, message) => sum + message.content.length, 0);
  const kept: AgentMessage[] = [];
  for (let index = recent.length - 1; index >= 0; index -= 1) {
    const message = recent[index];
    if (!message) continue;
    if (total + message.content.length > budget.maxChars && kept.length > 0) break;
    total += message.content.length;
    kept.unshift(message);
  }
  return [...system, ...dropOrphanToolMessages(kept)];
}
