import { createHash } from 'node:crypto';
import type { CIFailureKind } from './ci-log-classifier';

export interface CIRepairSessionInput {
  parentSessionID: string;
  projectPath: string;
  commit: string;
  runID: number;
  failure: { kind: CIFailureKind; summary: string };
  log: string;
}

export interface CIRepairSession {
  sessionID: string;
  parentSessionID: string;
  projectPath: string;
  commit: string;
  runID: number;
  failureKind: CIFailureKind;
  failureSummary: string;
  logHash: string;
  prompt: string;
}

function sha256(value: string): string {
  return createHash('sha256').update(value).digest('hex');
}

export function createCIRepairSession(input: CIRepairSessionInput): CIRepairSession {
  const log = input.log.slice(0, 200_000);
  const logHash = sha256(log);
  const sessionID = `ci-repair-${sha256(`${input.parentSessionID}\u0000${input.commit}\u0000${input.runID}`).slice(0, 24)}`;
  const prompt = [
    `你是一个独立的 CI 修复会话。请修复 GitHub Actions Run #${input.runID} 在 Commit ${input.commit} 上的失败。`,
    `失败分类：${input.failure.kind}。${input.failure.summary}`,
    '先阅读相关文件和项目规则；只修改与失败直接相关的内容；运行最小相关验证。不要创建新的 PR、不要 push、不要修改工作区外文件。',
    `失败日志（内容哈希 ${logHash}）：`,
    log
  ].join('\n\n');
  return {
    sessionID,
    parentSessionID: input.parentSessionID,
    projectPath: input.projectPath,
    commit: input.commit,
    runID: input.runID,
    failureKind: input.failure.kind,
    failureSummary: input.failure.summary,
    logHash,
    prompt
  };
}
