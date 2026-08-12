import { contextBridge, ipcRenderer } from 'electron';

interface ProviderDraft {
  id?: string;
  name: string;
  baseUrl: string;
  protocol: 'openai-compatible' | 'anthropic-compatible';
  model: string;
  apiKey: string;
}

const deepseekCode = {
  sessions: {
    list: () => ipcRenderer.invoke('sessions:list'),
    create: (input: { projectPath: string; title: string; mode: string }) => ipcRenderer.invoke('sessions:create', input),
    events: (sessionId: string) => ipcRenderer.invoke('sessions:events', sessionId),
    append: (sessionId: string, payload: unknown) => ipcRenderer.invoke('sessions:append', sessionId, payload)
  },
  workspace: {
    read: (root: string, path: string, range: { startLine: number; maxLines: number }) => ipcRenderer.invoke('workspace:read', root, path, range)
  },
  providers: {
    list: () => ipcRenderer.invoke('providers:list'),
    save: (input: ProviderDraft) => ipcRenderer.invoke('providers:save', input),
    test: (input: ProviderDraft) => ipcRenderer.invoke('providers:test', input)
  },
  agent: {
    run: (input: { sessionId: string; projectPath: string; prompt: string; providerProfileId: string; mode: string }) => ipcRenderer.invoke('agent:run', input),
    onEvent: (listener: (payload: unknown) => void) => {
      const handler = (_event: Electron.IpcRendererEvent, payload: unknown) => listener(payload);
      ipcRenderer.on('agent:event', handler);
      return () => ipcRenderer.removeListener('agent:event', handler);
    }
  },
  projects: {
    chooseFolder: () => ipcRenderer.invoke('projects:choose-folder')
  }
};

contextBridge.exposeInMainWorld('deepseekCode', deepseekCode);

export type DeepSeekCodeBridge = typeof deepseekCode;
