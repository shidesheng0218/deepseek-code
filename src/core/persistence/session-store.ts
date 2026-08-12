import { DatabaseSync } from 'node:sqlite';

export interface PersistedSession {
  id: string;
  projectPath: string;
  title: string;
  mode: string;
  createdAt?: string;
  updatedAt?: string;
}

export class SessionEventStore {
  private readonly database: DatabaseSync;

  constructor(filename: string) {
    this.database = new DatabaseSync(filename);
    this.database.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        project_path TEXT NOT NULL,
        title TEXT NOT NULL,
        mode TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS session_events (
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        sequence INTEGER NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (session_id, sequence)
      ) STRICT;
    `);
  }

  createSession(session: PersistedSession): void {
    const now = new Date().toISOString();
    this.database
      .prepare('INSERT INTO sessions (id, project_path, title, mode, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)')
      .run(session.id, session.projectPath, session.title, session.mode, session.createdAt ?? now, session.updatedAt ?? now);
  }

  append(sessionId: string, event: unknown): void {
    const row = this.database
      .prepare('SELECT COALESCE(MAX(sequence), 0) + 1 AS next_sequence FROM session_events WHERE session_id = ?')
      .get(sessionId) as { next_sequence: number };
    const now = new Date().toISOString();
    this.database.prepare('INSERT INTO session_events (session_id, sequence, payload, created_at) VALUES (?, ?, ?, ?)')
      .run(sessionId, row.next_sequence, JSON.stringify(event), now);
    this.database.prepare('UPDATE sessions SET updated_at = ? WHERE id = ?').run(now, sessionId);
  }

  listSessions(): PersistedSession[] {
    const rows = this.database.prepare('SELECT id, project_path, title, mode, created_at, updated_at FROM sessions ORDER BY updated_at DESC').all() as Array<{
      id: string;
      project_path: string;
      title: string;
      mode: string;
      created_at: string;
      updated_at: string;
    }>;
    return rows.map((row) => ({
      id: row.id,
      projectPath: row.project_path,
      title: row.title,
      mode: row.mode,
      createdAt: row.created_at,
      updatedAt: row.updated_at
    }));
  }

  loadEvents(sessionId: string): unknown[] {
    const rows = this.database.prepare('SELECT payload FROM session_events WHERE session_id = ? ORDER BY sequence ASC').all(sessionId) as Array<{ payload: string }>;
    return rows.map((row) => JSON.parse(row.payload) as unknown);
  }

  close(): void {
    this.database.close();
  }
}
