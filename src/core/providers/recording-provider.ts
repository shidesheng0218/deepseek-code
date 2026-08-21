import type { ModelEvent } from './openai-compatible';
import type { ChatRequestInput } from './openai-compatible';

/**
 * RecordingProvider（NEXT_GEN_ARCHITECTURE Phase 1 支柱一）：
 * 从 model_stream_recorded 事件回放录制的模型流，用于确定性回放验证。
 *
 * 用途：
 * - session.replay：重放会话并逐事件匹配验证一致性
 * - Shadow eval：离线对比不同上下文策略的 token 消耗
 * - 崩溃会话调试：replay 到崩溃点，检查为什么会走到那条路径
 */

export interface RecordedDelta {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  arguments?: Record<string, unknown>;
  inputTokens?: number;
  outputTokens?: number;
  cachedInputTokens?: number;
}

export interface RecordedTurn {
  turnSequence: number;
  model: string;
  deltas: RecordedDelta[];
}

export class RecordingProvider {
  private turnIndex = 0;

  constructor(private readonly recordedTurns: RecordedTurn[]) {}

  async *stream(input: ChatRequestInput): AsyncGenerator<ModelEvent> {
    if (this.turnIndex >= this.recordedTurns.length) {
      throw new Error(`RecordingProvider: no recorded turn at index ${this.turnIndex} (only ${this.recordedTurns.length} turns recorded)`);
    }

    const turn = this.recordedTurns[this.turnIndex];
    if (!turn) {
      throw new Error(`RecordingProvider: recorded turn at index ${this.turnIndex} is undefined`);
    }
    this.turnIndex += 1;

    // 按序吐出录制的 delta
    for (const delta of turn.deltas) {
      if (delta.type === 'text_delta' && delta.text !== undefined) {
        yield { type: 'text_delta', text: delta.text };
      } else if (delta.type === 'tool_call' && delta.id && delta.name && delta.arguments) {
        yield { type: 'tool_call', id: delta.id, name: delta.name, arguments: delta.arguments };
      } else if (delta.type === 'usage' && delta.inputTokens !== undefined && delta.outputTokens !== undefined) {
        yield {
          type: 'usage',
          inputTokens: delta.inputTokens,
          outputTokens: delta.outputTokens,
          cachedInputTokens: delta.cachedInputTokens ?? 0
        };
      } else if (delta.type === 'done') {
        yield { type: 'done' };
      }
    }
  }

  /** 重置回放位置（用于多次回放同一录制） */
  reset(): void {
    this.turnIndex = 0;
  }

  /** 当前已消耗的 turn 数量 */
  consumedTurns(): number {
    return this.turnIndex;
  }
}
