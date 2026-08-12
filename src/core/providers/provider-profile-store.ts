import { DatabaseSync } from 'node:sqlite';

export interface ProviderProfile {
  id: string;
  name: string;
  baseUrl: string;
  protocol: 'openai-compatible' | 'anthropic-compatible';
  model: string;
  apiKeyRef: string;
  inputPerMillion: number;
  cachedInputPerMillion: number;
  outputPerMillion: number;
}

export class ProviderProfileStore {
  private readonly database: DatabaseSync;

  constructor(filename: string) {
    this.database = new DatabaseSync(filename);
    this.database.exec(`
      CREATE TABLE IF NOT EXISTS provider_profiles (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        base_url TEXT NOT NULL,
        protocol TEXT NOT NULL,
        model TEXT NOT NULL,
        api_key_ref TEXT NOT NULL,
        input_per_million REAL NOT NULL,
        cached_input_per_million REAL NOT NULL,
        output_per_million REAL NOT NULL
      ) STRICT;
    `);
  }

  save(profile: ProviderProfile): void {
    this.database.prepare(`
      INSERT INTO provider_profiles (
        id, name, base_url, protocol, model, api_key_ref,
        input_per_million, cached_input_per_million, output_per_million
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        base_url = excluded.base_url,
        protocol = excluded.protocol,
        model = excluded.model,
        api_key_ref = excluded.api_key_ref,
        input_per_million = excluded.input_per_million,
        cached_input_per_million = excluded.cached_input_per_million,
        output_per_million = excluded.output_per_million
    `).run(
      profile.id,
      profile.name,
      profile.baseUrl,
      profile.protocol,
      profile.model,
      profile.apiKeyRef,
      profile.inputPerMillion,
      profile.cachedInputPerMillion,
      profile.outputPerMillion
    );
  }

  list(): ProviderProfile[] {
    const rows = this.database.prepare(`
      SELECT id, name, base_url, protocol, model, api_key_ref,
             input_per_million, cached_input_per_million, output_per_million
      FROM provider_profiles ORDER BY name COLLATE NOCASE
    `).all() as Array<Record<string, string | number>>;
    return rows.map((row) => ({
      id: String(row.id),
      name: String(row.name),
      baseUrl: String(row.base_url),
      protocol: String(row.protocol) as ProviderProfile['protocol'],
      model: String(row.model),
      apiKeyRef: String(row.api_key_ref),
      inputPerMillion: Number(row.input_per_million),
      cachedInputPerMillion: Number(row.cached_input_per_million),
      outputPerMillion: Number(row.output_per_million)
    }));
  }

  close(): void {
    this.database.close();
  }
}
