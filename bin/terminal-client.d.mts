export type RunOptions = {
  projectPath?: string;
  model?: string;
  baseURL?: string;
  protocol?: string;
  mode?: string;
  sessionID?: string;
  fastModel?: string;
};
export function runSettings(options?: RunOptions, env?: NodeJS.ProcessEnv, config?: { values: Record<string, string | undefined> }): Promise<{
  sessionID: string;
  projectPath: string;
  baseURL: string;
  apiKey: string;
  model: string;
  protocol: string;
  mode: string;
  fastModel?: string;
}>;
export function terminalSession(options: Record<string, unknown>): Promise<void>;
export class RuntimeClient {
  constructor(binary: string, cwd: string, sessionID: string);
  onEvent: (event: Record<string, unknown>) => void;
  request(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>>;
  close(): Promise<void>;
}
