import { createHash } from 'node:crypto';

/**
 * 交付回执（NEXT_GEN_ARCHITECTURE 支柱二 v0）。
 *
 * 回执把一次 delivered 绑定到可复核的密码学对象上：
 * - logHash：覆盖事件日志 [fromSequence, toSequence] 区间的规范化 SHA-256
 *   （键序无关的 canonical JSON），篡改任一字段都会失配；
 * - gate：交付门禁状态在回执覆盖区间内可独立重算比对；
 * - evidence：每条验证证据带 payload 哈希，可逐条重算。
 *
 * v0 不做签名校验（minisign 在 Phase 1 接入 updater 密钥基建），
 * 哈希链已能支撑"同一份日志、同一个结论"的离线复核。
 */

export interface ReceiptEvidence {
  kind: 'tests' | 'browser' | 'ci' | 'verification';
  command?: string;
  exitCode?: number;
  payloadHash: string;
  capturedAt?: string;
}

export interface DeliveryReceipt {
  schemaVersion: 1;
  receiptID: string;
  sessionID: string;
  issuedAt: string;
  project: { path: string; headCommit?: string; branch?: string };
  gate: { state: string; reasons: string[] };
  evidence: ReceiptEvidence[];
  events: { fromSequence: number; toSequence: number; logHash: string };
}

export interface ReceiptEvent {
  sequence?: number;
  type: string;
  payload?: Record<string, unknown>;
}

export interface ReceiptCheck {
  name: string;
  ok: boolean;
  detail: string;
}

/** 规范化序列化：对象键排序，数组保序——哈希与键序无关、与内容一一对应。 */
export function canonicalize(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value as Record<string, unknown>).sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalize((value as Record<string, unknown>)[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value) ?? 'null';
}

export function sha256(text: string): string {
  return createHash('sha256').update(text).digest('hex');
}

export function computeLogHash(events: ReceiptEvent[]): string {
  return sha256(events.map((event) => canonicalize({ sequence: event.sequence ?? 0, type: event.type, payload: event.payload ?? {} })).join('\n'));
}

function evidenceFrom(events: ReceiptEvent[]): ReceiptEvidence[] {
  const evidence: ReceiptEvidence[] = [];
  for (const event of events) {
    const payload = event.payload ?? {};
    const payloadHash = sha256(canonicalize(payload));
    if (event.type === 'verification_passed') {
      evidence.push({
        kind: 'verification',
        ...(typeof payload.kind === 'string' ? { command: `${payload.kind}:${typeof payload.command === 'string' ? payload.command : ''}` } : {}),
        payloadHash
      });
    } else if (event.type === 'terminal_completed' && payload.exitCode === 0 && typeof payload.command === 'string') {
      evidence.push({ kind: 'tests', command: payload.command, exitCode: 0, payloadHash });
    } else if (event.type === 'browser_evidence' && payload.ok === true) {
      evidence.push({ kind: 'browser', ...(typeof payload.url === 'string' ? { command: payload.url } : {}), payloadHash });
    } else if (event.type === 'ci_status' && payload.passed === true) {
      evidence.push({ kind: 'ci', ...(typeof payload.commit === 'string' ? { command: payload.commit } : {}), payloadHash });
    }
  }
  return evidence;
}

export interface BuildReceiptInput {
  sessionID: string;
  events: ReceiptEvent[];
  gate: { state: string; reasons: string[] };
  projectPath: string;
  headCommit?: string;
  branch?: string;
  receiptID: string;
  issuedAt: string;
}

export function buildDeliveryReceipt(input: BuildReceiptInput): DeliveryReceipt {
  const sequenced = input.events.filter((event) => typeof event.sequence === 'number');
  const toSequence = sequenced.reduce((max, event) => Math.max(max, event.sequence ?? 0), 0);
  const fromSequence = sequenced.length ? Math.min(...sequenced.map((event) => event.sequence ?? 0)) : 0;
  return {
    schemaVersion: 1,
    receiptID: input.receiptID,
    sessionID: input.sessionID,
    issuedAt: input.issuedAt,
    project: { path: input.projectPath, ...(input.headCommit ? { headCommit: input.headCommit } : {}), ...(input.branch ? { branch: input.branch } : {}) },
    gate: { state: input.gate.state, reasons: input.gate.reasons },
    evidence: evidenceFrom(input.events),
    events: { fromSequence, toSequence, logHash: computeLogHash(sequenced) }
  };
}

export interface VerifyReceiptInput {
  receipt: DeliveryReceipt;
  /** 会话事件（可超出回执覆盖区间，校验时按 toSequence 截断） */
  events: ReceiptEvent[];
  /** 重算交付门禁（由调用方注入，保持本模块与门禁实现解耦） */
  evaluateGate: (events: ReceiptEvent[]) => { state: string; reasons: string[] };
}

export function verifyDeliveryReceipt(input: VerifyReceiptInput): { ok: boolean; checks: ReceiptCheck[] } {
  const { receipt } = input;
  const checks: ReceiptCheck[] = [];
  const bounded = input.events.filter((event) => typeof event.sequence === 'number' && (event.sequence ?? 0) <= receipt.events.toSequence);

  const recomputedHash = computeLogHash(bounded);
  checks.push({
    name: 'logHash',
    ok: recomputedHash === receipt.events.logHash,
    detail: recomputedHash === receipt.events.logHash ? `区间 [${receipt.events.fromSequence}, ${receipt.events.toSequence}] 哈希一致` : '事件日志哈希失配（内容被篡改或区间不符）'
  });

  const gate = input.evaluateGate(bounded);
  checks.push({
    name: 'gate',
    ok: gate.state === receipt.gate.state,
    detail: gate.state === receipt.gate.state ? `门禁重算一致：${gate.state}` : `门禁重算为 ${gate.state}，回执声称 ${receipt.gate.state}`
  });

  const evidenceHashes = new Set(receipt.evidence.map((item) => item.payloadHash));
  const present = evidenceFrom(bounded).map((item) => item.payloadHash);
  const evidenceOk = present.length === evidenceHashes.size && present.every((hash) => evidenceHashes.has(hash));
  checks.push({
    name: 'evidence',
    ok: evidenceOk,
    detail: evidenceOk ? `${receipt.evidence.length} 条证据哈希逐条一致` : '证据集合与回执不符'
  });

  checks.push({
    name: 'structure',
    ok: receipt.schemaVersion === 1 && Boolean(receipt.receiptID && receipt.sessionID && receipt.issuedAt),
    detail: receipt.schemaVersion === 1 ? '结构字段完整' : `不支持的 schemaVersion：${String(receipt.schemaVersion)}`
  });

  return { ok: checks.every((check) => check.ok), checks };
}
