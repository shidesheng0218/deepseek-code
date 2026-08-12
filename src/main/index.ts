import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { app, BrowserWindow, dialog, ipcMain, safeStorage, shell } from 'electron';
import { SessionEventStore } from '../core/persistence/session-store';
import { readWorkspaceFile } from '../core/tools/workspace';
import { ProviderProfileStore, type ProviderProfile } from '../core/providers/provider-profile-store';
import { SecretVault } from '../core/security/secret-vault';
import { AgentExecutor, type AgentExecutorEvent, type AgentMessage } from '../core/agent-executor';
import { OpenAICompatibleClient } from '../core/providers/openai-compatible';
import { createWorkspaceAgentTools } from '../core/tools/agent-tools';
import type { AgentMode } from '../core/permissions';
import { estimateUsageCost } from '../core/usage';

let mainWindow: BrowserWindow | undefined;
let sessionStore: SessionEventStore | undefined;
let providerStore: ProviderProfileStore | undefined;
let secretVault: SecretVault | undefined;

const AGENT_TOOL_SCHEMAS = [
  { type: 'function', function: { name: 'list_directory', description: '列出工作区目录', parameters: { type: 'object', properties: { path: { type: 'string' } }, required: [] } } },
  { type: 'function', function: { name: 'search_workspace', description: '在工作区内搜索文本', parameters: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] } } },
  { type: 'function', function: { name: 'read_file', description: '读取工作区文件', parameters: { type: 'object', properties: { path: { type: 'string' }, startLine: { type: 'number' }, maxLines: { type: 'number' } }, required: ['path'] } } },
  { type: 'function', function: { name: 'apply_patch', description: '以检查点和哈希校验为前提修改文件', parameters: { type: 'object', properties: { label: { type: 'string' }, changes: { type: 'array', items: { type: 'object', properties: { path: { type: 'string' }, content: { type: 'string' }, expectedHash: { type: 'string' } }, required: ['path', 'content'] } } }, required: ['changes'] } } },
  { type: 'function', function: { name: 'inspect_git', description: '查看 Git 状态', parameters: { type: 'object', properties: {}, required: [] } } },
  { type: 'function', function: { name: 'run_command', description: '在工作区目录运行命令；高风险命令会请求审批', parameters: { type: 'object', properties: { command: { type: 'string' }, timeoutMs: { type: 'number' } }, required: ['command'] } } }
];

function redact(value: string): string {
  return value.replace(/(sk-[A-Za-z0-9_-]{8,})/g, '[REDACTED_KEY]').replace(/(Bearer\s+)[^\s]+/gi, '$1[REDACTED]');
}

function appendAgentEvent(sessionId: string, event: AgentExecutorEvent): void {
  const safeEvent = {
    ...event,
    ...('output' in event && typeof event.output === 'string' ? { output: redact(event.output) } : {}),
    ...('error' in event && typeof event.error === 'string' ? { error: redact(event.error) } : {})
  };
  getSessionStore().append(sessionId, { type: 'agent_event', event: safeEvent });
  mainWindow?.webContents.send('agent:event', { sessionId, event: safeEvent });
}

function getSessionStore(): SessionEventStore {
  if (!sessionStore) {
    sessionStore = new SessionEventStore(join(app.getPath('userData'), 'deepseek-code.sqlite'));
  }
  return sessionStore;
}

function getProviderStore(): ProviderProfileStore {
  if (!providerStore) providerStore = new ProviderProfileStore(join(app.getPath('userData'), 'deepseek-code.sqlite'));
  return providerStore;
}

function getSecretVault(): SecretVault {
  if (!secretVault) {
    secretVault = new SecretVault({
      storagePath: join(app.getPath('userData'), 'secrets.json'),
      crypto: {
        isEncryptionAvailable: () => safeStorage.isEncryptionAvailable(),
        encryptString: (value) => safeStorage.encryptString(value),
        decryptString: (value) => safeStorage.decryptString(value)
      }
    });
  }
  return secretVault;
}

interface ProviderInput {
  id?: string;
  name: string;
  baseUrl: string;
  protocol: ProviderProfile['protocol'];
  model: string;
  apiKey: string;
}

function validateProviderInput(input: ProviderInput): void {
  const url = new URL(input.baseUrl);
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Base URL 必须使用 HTTP 或 HTTPS');
  if (!input.name.trim() || !input.model.trim()) throw new Error('Provider 名称和模型不能为空');
  if (!['openai-compatible', 'anthropic-compatible'].includes(input.protocol)) throw new Error('不支持的协议');
}

function providerPublicProfile(profile: ProviderProfile): Omit<ProviderProfile, 'apiKeyRef'> {
  const publicProfile = { ...profile } as Partial<ProviderProfile>;
  delete publicProfile.apiKeyRef;
  return publicProfile as Omit<ProviderProfile, 'apiKeyRef'>;
}

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1500,
    height: 940,
    minWidth: 1080,
    minHeight: 680,
    backgroundColor: '#0d0f14',
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true
    }
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: 'deny' };
  });

  const devUrl = process.env.ELECTRON_RENDERER_URL;
  if (devUrl) {
    void mainWindow.loadURL(devUrl);
  } else {
    void mainWindow.loadFile(join(__dirname, '../renderer/index.html'));
  }
}

function registerIpc(): void {
  ipcMain.handle('sessions:list', () => getSessionStore().listSessions());
  ipcMain.handle('sessions:create', (_event, input: { projectPath: string; title: string; mode: string }) => {
    const id = randomUUID();
    getSessionStore().createSession({ id, ...input });
    return id;
  });
  ipcMain.handle('sessions:events', (_event, sessionId: string) => getSessionStore().loadEvents(sessionId));
  ipcMain.handle('sessions:append', (_event, sessionId: string, payload: unknown) => getSessionStore().append(sessionId, payload));
  ipcMain.handle('workspace:read', (_event, root: string, path: string, range: { startLine: number; maxLines: number }) => readWorkspaceFile(root, path, range));
  ipcMain.handle('projects:choose-folder', async () => {
    const result = await dialog.showOpenDialog({ properties: ['openDirectory', 'createDirectory'] });
    return result.canceled ? undefined : result.filePaths[0];
  });
  ipcMain.handle('providers:list', () => getProviderStore().list().map(providerPublicProfile));
  ipcMain.handle('providers:save', async (_event, input: ProviderInput) => {
    validateProviderInput(input);
    const id = input.id?.trim() || randomUUID();
    const keyRef = `keychain://${id}`;
    if (input.apiKey.trim()) await getSecretVault().save(keyRef, input.apiKey);
    const existing = getProviderStore().list().find((profile) => profile.id === id);
    const profile: ProviderProfile = {
      id,
      name: input.name.trim(),
      baseUrl: input.baseUrl.trim().endsWith('/') ? input.baseUrl.trim() : `${input.baseUrl.trim()}/`,
      protocol: input.protocol,
      model: input.model.trim(),
      apiKeyRef: input.apiKey.trim() ? keyRef : existing?.apiKeyRef ?? keyRef,
      inputPerMillion: existing?.inputPerMillion ?? 0,
      cachedInputPerMillion: existing?.cachedInputPerMillion ?? 0,
      outputPerMillion: existing?.outputPerMillion ?? 0
    };
    getProviderStore().save(profile);
    return providerPublicProfile(profile);
  });
  ipcMain.handle('providers:test', async (_event, input: ProviderInput) => {
    validateProviderInput(input);
    const id = input.id?.trim();
    const savedProfile = id ? getProviderStore().list().find((profile) => profile.id === id) : undefined;
    const apiKey = input.apiKey.trim() || (savedProfile ? await getSecretVault().load(savedProfile.apiKeyRef) : undefined);
    if (!apiKey) return { ok: false, error: '请先填写 API Key' };
    const endpoint = new URL('models', input.baseUrl.endsWith('/') ? input.baseUrl : `${input.baseUrl}/`);
    const response = await fetch(endpoint, { headers: { Authorization: `Bearer ${apiKey}`, Accept: 'application/json' } });
    if (!response.ok) return { ok: false, error: `HTTP ${response.status}` };
    return { ok: true };
  });
  ipcMain.handle('agent:run', async (_event, input: { sessionId: string; projectPath: string; prompt: string; providerProfileId: string; mode: AgentMode }) => {
    if (!input.prompt.trim()) throw new Error('任务描述不能为空');
    const profile = getProviderStore().list().find((item) => item.id === input.providerProfileId);
    if (!profile) throw new Error('Provider 未配置');
    const apiKey = await getSecretVault().load(profile.apiKeyRef);
    if (!apiKey) throw new Error('Provider API Key 不可用');
    if (!getSessionStore().listSessions().some((session) => session.id === input.sessionId)) {
      getSessionStore().createSession({ id: input.sessionId, projectPath: input.projectPath, title: input.prompt.slice(0, 60), mode: input.mode });
    }
    const client = new OpenAICompatibleClient({ baseUrl: profile.baseUrl, apiKey });
    const tools = createWorkspaceAgentTools({ root: input.projectPath, checkpointRoot: join(app.getPath('userData'), 'checkpoints', input.sessionId) });
    const executor = new AgentExecutor({
      mode: input.mode,
      model: {
        stream: async function* (messages: AgentMessage[]) {
          const startedAt = Date.now();
          const modelMessages = messages.map((message) => ({ role: message.role, content: message.content, ...(message.toolCallId === undefined ? {} : { toolCallId: message.toolCallId }) }));
          for await (const event of client.stream({ model: profile.model, messages: modelMessages, feature: 'main_agent', tools: AGENT_TOOL_SCHEMAS })) {
            if (event.type === 'text_delta' || event.type === 'tool_call') yield event;
            if (event.type === 'usage') {
              getSessionStore().append(input.sessionId, {
                type: 'usage_recorded',
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                cachedInputTokens: event.cachedInputTokens,
                estimatedCost: estimateUsageCost(profile, event),
                model: profile.model,
                feature: 'main_agent',
                latencyMs: Date.now() - startedAt
              });
            }
          }
        }
      },
      tools: {
        list_directory: tools.list_directory,
        search_workspace: tools.search_workspace,
        read_file: tools.read_file,
        apply_patch: tools.apply_patch,
        inspect_git: tools.inspect_git,
        run_command: tools.run_command
      },
      onEvent: (event) => appendAgentEvent(input.sessionId, event)
    });
    getSessionStore().append(input.sessionId, { type: 'session_status_changed', status: 'running' });
    try {
      const result = await executor.run(input.sessionId, input.prompt);
      getSessionStore().append(input.sessionId, { type: 'session_status_changed', status: result.status === 'waiting_approval' ? 'waiting_approval' : 'completed' });
      return { text: result.text, status: result.status, messages: result.messages };
    } catch (error) {
      getSessionStore().append(input.sessionId, { type: 'session_status_changed', status: 'failed' });
      throw error;
    }
  });
}

app.whenReady().then(() => {
  registerIpc();
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('before-quit', () => {
  sessionStore?.close();
  providerStore?.close();
});
