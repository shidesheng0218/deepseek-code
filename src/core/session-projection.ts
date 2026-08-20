import { mkdir, readdir, readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type { AgentMessage } from './agent-executor';

/**
 * 会话投影层：JSONL 事件日志的 SQLite 物化视图（NEXT_GEN_ARCHITECTURE 支柱一）。
 *
 * 纪律：JSONL 永远是真源，投影只是可整体丢弃重建的缓存。
 * 任何读取路径在投影缺失/损坏时都必须能退回扫描 JSONL。
 *
 * 运行环境适配：sidecar 用 bun:sqlite，vitest/CLI 用 node:sqlite，
 * 两者 API 同构（exec / prepare().run|get|all），通过动态 import 选择。
 */

export interface ProjectedEventInput {
  sessionID: string;
  sequence: number;
  eventID?: string;
  type: string;
  payload: Record<string, unknown>;
  createdAt: string;
}

export interface SessionSummaryRow {
  sessionID: string;
  title: string;
  projectPath: string;
  /** 最近一次事件的毫秒时间戳 */
  updatedAt: number;
  eventCount: number;
}

export interface ModelTokenRow {
  model: string;
  tokens: number;
}

export interface UsageStatsRow {
  sessions: number;
  messages: number;
  totalTokens: number;
  inputTokens: number;
  outputTokens: number;
  cachedTokens: number;
  activeDays: number;
  currentStreak: number;
  longestStreak: number;
  peakHour: number | null;
  favoriteModel: string | null;
  /** 140 天逐日事件计数（本地时区，升序到今天） */
  dailyActivity: number[];
  dailyStart: string | null;
  modelTokens: ModelTokenRow[];
}

export interface Projection {
  recordEvent(event: ProjectedEventInput): void;
  listSessions(): SessionSummaryRow[];
  usageStats(days?: number, now?: Date): UsageStatsRow;
  /** 重建会话到某个事件水位（含）为止的对话；不传 throughSequence 则为全量 */
  conversationAt(sessionID: string, throughSequence?: number): AgentMessage[];
  eventsOf(sessionID: string): ProjectedEventInput[];
  sessionEventCount(sessionID: string): number;
  /** 从 JSONL 目录全量重建（或追平单个会话）；返回重建的会话与事件数 */
  rebuildFromJsonl(root: string): Promise<{ sessions: number; events: number }>;
  close(): void;
}

interface SqliteStatement {
  run(...params: Array<string | number | null>): unknown;
  get(...params: Array<string | number | null>): Record<string, unknown> | undefined;
  all(...params: Array<string | number | null>): Array<Record<string, unknown>>;
}

interface SqliteDatabase {
  exec(sql: string): unknown;
  prepare(sql: string): SqliteStatement;
  close(): void;
}

async function openDatabase(dbPath: string): Promise<SqliteDatabase> {
  try {
    const bunSqlite = await import('bun:sqlite') as { Database?: new (path: string) => SqliteDatabase };
    if (bunSqlite.Database) return new bunSqlite.Database(dbPath);
  } catch { /* 非 Bun 环境，落到 node:sqlite */ }
  const nodeSqlite = await import('node:sqlite') as { DatabaseSync?: new (path: string) => SqliteDatabase };
  if (!nodeSqlite.DatabaseSync) throw new Error('No SQLite backend available (need bun:sqlite or node:sqlite)');
  return new nodeSqlite.DatabaseSync(dbPath);
}

const SCHEMA = `
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS events (
  session_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  event_id TEXT NOT NULL DEFAULT '',
  type TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (session_id, sequence)
);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(type, created_at);
CREATE TABLE IF NOT EXISTS sessions (
  session_id TEXT PRIMARY KEY,
  title TEXT,
  project_path TEXT,
  created_at TEXT,
  updated_at TEXT,
  event_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS usage (
  session_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  model TEXT NOT NULL DEFAULT '',
  input_tokens INTEGER NOT NULL DEFAULT 0,
  cached_input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  PRIMARY KEY (session_id, sequence)
);
`;

function asNumber(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function formatLocalDay(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

/** 以本地时区的 YYYY-MM-DD 归组（与 Rust compute_usage_stats 的 Local::now 语义一致） */
function localDay(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  return formatLocalDay(date);
}

function addDays(day: string, delta: number): string {
  const [y, m, d] = day.split('-').map((part) => Number.parseInt(part, 10));
  const date = new Date(y ?? 1970, (m ?? 1) - 1, d ?? 1);
  date.setDate(date.getDate() + delta);
  return formatLocalDay(date);
}

export async function openProjection(dbPath: string): Promise<Projection> {
  if (dbPath !== ':memory:') await mkdir(dirname(dbPath), { recursive: true });
  const db = await openDatabase(dbPath);
  db.exec(SCHEMA);

  const insertEvent = db.prepare('INSERT OR REPLACE INTO events (session_id, sequence, event_id, type, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)');
  const upsertSession = db.prepare(`
    INSERT INTO sessions (session_id, title, project_path, created_at, updated_at, event_count)
    VALUES (?, NULL, NULL, ?, ?, 1)
    ON CONFLICT(session_id) DO UPDATE SET updated_at = MAX(updated_at, excluded.updated_at), event_count = event_count + 1
  `);
  const setSessionMeta = db.prepare(`
    UPDATE sessions SET
      title = COALESCE(title, ?),
      project_path = COALESCE(project_path, ?)
    WHERE session_id = ?
  `);
  const insertUsage = db.prepare('INSERT OR REPLACE INTO usage (session_id, sequence, model, input_tokens, cached_input_tokens, output_tokens, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)');

  function recordEvent(event: ProjectedEventInput): void {
    insertEvent.run(event.sessionID, event.sequence, event.eventID ?? '', event.type, JSON.stringify(event.payload ?? {}), event.createdAt);
    upsertSession.run(event.sessionID, event.createdAt, event.createdAt);
    if (event.type === 'turn_started') {
      const prompt = asString(event.payload.prompt);
      const title = prompt.length > 56 ? `${[...prompt].slice(0, 56).join('')}…` : prompt;
      setSessionMeta.run(title || null, asString(event.payload.projectPath) || null, event.sessionID);
    }
    if (event.type === 'usage_recorded') {
      insertUsage.run(
        event.sessionID,
        event.sequence,
        asString(event.payload.model),
        asNumber(event.payload.inputTokens),
        asNumber(event.payload.cachedInputTokens),
        asNumber(event.payload.outputTokens),
        event.createdAt
      );
    }
  }

  function eventsOf(sessionID: string): ProjectedEventInput[] {
    return db.prepare('SELECT session_id, sequence, event_id, type, payload, created_at FROM events WHERE session_id = ? ORDER BY sequence')
      .all(sessionID)
      .map((row) => ({
        sessionID: asString(row.session_id),
        sequence: asNumber(row.sequence),
        eventID: asString(row.event_id),
        type: asString(row.type),
        payload: JSON.parse(asString(row.payload) || '{}') as Record<string, unknown>,
        createdAt: asString(row.created_at)
      }));
  }

  return {
    recordEvent,

    listSessions(): SessionSummaryRow[] {
      return db.prepare('SELECT session_id, title, project_path, updated_at, event_count FROM sessions ORDER BY updated_at DESC')
        .all()
        .map((row) => ({
          sessionID: asString(row.session_id),
          title: asString(row.title) || asString(row.session_id),
          projectPath: asString(row.project_path),
          updatedAt: Date.parse(asString(row.updated_at)) || 0,
          eventCount: asNumber(row.event_count)
        }));
    },

    usageStats(days?: number, now: Date = new Date()): UsageStatsRow {
      const stats: UsageStatsRow = {
        sessions: 0, messages: 0, totalTokens: 0, inputTokens: 0, outputTokens: 0, cachedTokens: 0,
        activeDays: 0, currentStreak: 0, longestStreak: 0, peakHour: null, favoriteModel: null,
        dailyActivity: [], dailyStart: null, modelTokens: []
      };
      const cutoff = days === undefined ? null : addDays(localDay(now.toISOString()), -days);
      const inWindow = (createdAt: string): boolean => cutoff === null || localDay(createdAt) >= cutoff;

      const events = db.prepare('SELECT session_id, type, payload, created_at FROM events').all()
        .map((row) => ({ sessionID: asString(row.session_id), type: asString(row.type), payload: asString(row.payload), createdAt: asString(row.created_at) }))
        .filter((row) => inWindow(row.createdAt));

      const sessionsInWindow = new Set(events.map((row) => row.sessionID));
      stats.sessions = sessionsInWindow.size;
      const daySet = new Set<string>();
      const daily = new Map<string, number>();
      const hours = new Array<number>(24).fill(0);
      for (const event of events) {
        const day = localDay(event.createdAt);
        if (!day) continue;
        daySet.add(day);
        daily.set(day, (daily.get(day) ?? 0) + 1);
        if (event.type === 'turn_started') {
          stats.messages += 1;
          const hour = new Date(event.createdAt).getHours();
          if (!Number.isNaN(hour)) hours[hour] = (hours[hour] ?? 0) + 1;
        } else if (event.type === 'turn_ended') stats.messages += 1;
      }
      stats.activeDays = daySet.size;

      const usageRows = db.prepare('SELECT model, input_tokens, cached_input_tokens, output_tokens, created_at FROM usage').all()
        .map((row) => ({ model: asString(row.model), input: asNumber(row.input_tokens), cached: asNumber(row.cached_input_tokens), output: asNumber(row.output_tokens), createdAt: asString(row.created_at) }))
        .filter((row) => inWindow(row.createdAt));
      const models = new Map<string, number>();
      for (const row of usageRows) {
        stats.inputTokens += row.input;
        stats.outputTokens += row.output;
        stats.cachedTokens += row.cached;
        stats.totalTokens += row.input + row.output;
        if (row.model) models.set(row.model, (models.get(row.model) ?? 0) + row.input + row.output);
      }

      const today = localDay(now.toISOString());
      const heatmapStart = addDays(today, -139);
      stats.dailyStart = heatmapStart;
      stats.dailyActivity = Array.from({ length: 140 }, (_, index) => daily.get(addDays(heatmapStart, index)) ?? 0);

      const streakFrom = (anchor: string): number => {
        let streak = 0;
        let day = anchor;
        while (daySet.has(day)) { streak += 1; day = addDays(day, -1); }
        return streak;
      };
      stats.currentStreak = daySet.has(today) ? streakFrom(today) : streakFrom(addDays(today, -1));
      let longest = 0;
      let run = 0;
      let previous: string | null = null;
      for (const day of [...daySet].sort()) {
        run = previous !== null && day === addDays(previous, 1) ? run + 1 : 1;
        longest = Math.max(longest, run);
        previous = day;
      }
      stats.longestStreak = longest;

      let peakHour: number | null = null;
      let peakCount = 0;
      hours.forEach((count, hour) => { if (count > peakCount) { peakCount = count; peakHour = hour; } });
      stats.peakHour = peakHour;

      stats.modelTokens = [...models.entries()].map(([model, tokens]) => ({ model, tokens })).sort((a, b) => b.tokens - a.tokens);
      stats.favoriteModel = stats.modelTokens[0]?.model ?? null;
      return stats;
    },

    conversationAt(sessionID: string, throughSequence?: number): AgentMessage[] {
      const events = eventsOf(sessionID).filter((event) => throughSequence === undefined || event.sequence <= throughSequence);
      const messages: AgentMessage[] = [];
      let assistant = '';
      for (const event of events) {
        if (event.type === 'turn_started' && typeof event.payload.prompt === 'string') messages.push({ role: 'user', content: event.payload.prompt });
        if (event.type === 'assistant_text' && typeof event.payload.text === 'string') assistant += event.payload.text;
        if (event.type === 'turn_ended') {
          if (assistant) messages.push({ role: 'assistant', content: assistant });
          assistant = '';
        }
      }
      return messages.slice(-24);
    },

    eventsOf,

    sessionEventCount(sessionID: string): number {
      const row = db.prepare('SELECT COUNT(*) AS count FROM events WHERE session_id = ?').get(sessionID);
      return asNumber(row?.count);
    },

    async rebuildFromJsonl(root: string): Promise<{ sessions: number; events: number }> {
      let files: string[] = [];
      try { files = await readdir(root); } catch { return { sessions: 0, events: 0 }; }
      let sessions = 0;
      let eventCount = 0;
      for (const file of files.filter((name) => name.endsWith('.jsonl'))) {
        const sessionID = file.slice(0, -'.jsonl'.length);
        let lines: string[] = [];
        try { lines = (await readFile(join(root, file), 'utf8')).split('\n').filter(Boolean); } catch { continue; }
        db.prepare('DELETE FROM events WHERE session_id = ?').run(sessionID);
        db.prepare('DELETE FROM usage WHERE session_id = ?').run(sessionID);
        db.prepare('DELETE FROM sessions WHERE session_id = ?').run(sessionID);
        let sequence = 0;
        for (const line of lines) {
          let parsed: { eventID?: unknown; type?: unknown; payload?: unknown; createdAt?: unknown };
          try { parsed = JSON.parse(line) as typeof parsed; } catch { continue; }
          if (typeof parsed.type !== 'string') continue;
          sequence += 1;
          recordEvent({
            sessionID,
            sequence,
            ...(typeof parsed.eventID === 'string' ? { eventID: parsed.eventID } : {}),
            type: parsed.type,
            payload: parsed.payload && typeof parsed.payload === 'object' && !Array.isArray(parsed.payload) ? parsed.payload as Record<string, unknown> : {},
            createdAt: typeof parsed.createdAt === 'string' ? parsed.createdAt : new Date(0).toISOString()
          });
          eventCount += 1;
        }
        sessions += 1;
      }
      return { sessions, events: eventCount };
    },

    close(): void { db.close(); }
  };
}
