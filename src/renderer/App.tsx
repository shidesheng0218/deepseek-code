import {
  Activity,
  Bot,
  CheckCircle2,
  ChevronDown,
  Code2,
  FileCode2,
  GitBranch,
  Globe2,
  LayoutPanelTop,
  MoreHorizontal,
  PanelBottom,
  Play,
  Plus,
  Search,
  Settings2,
  ShieldCheck,
  Sparkles,
  TerminalSquare,
  TimerReset,
  Wrench,
  X,
  CheckCircle
} from 'lucide-react';
import { useMemo, useState } from 'react';
import './styles.css';

type AgentMode = 'Plan' | 'Manual' | 'Accept Edits' | 'Auto';
type RightPanel = 'Changes' | 'Files' | 'Browser' | 'Review';

interface SessionItem {
  id: string;
  title: string;
  target: 'Local' | 'Worktree' | 'SSH';
  branch: string;
  status: 'Running' | 'Waiting' | 'Needs review' | 'Completed';
  cost: string;
}

const SESSIONS: SessionItem[] = [
  { id: 'login', title: '修复登录状态同步', target: 'Worktree', branch: 'deepseek/fix-auth-sync', status: 'Running', cost: '¥0.18' },
  { id: 'review', title: '审查支付模块', target: 'Local', branch: 'main', status: 'Needs review', cost: '¥0.09' },
  { id: 'perf', title: '分析首屏性能', target: 'Worktree', branch: 'deepseek/perf-audit', status: 'Waiting', cost: '¥0.04' },
  { id: 'deps', title: '升级依赖并验证', target: 'SSH', branch: 'release/1.4', status: 'Completed', cost: '¥0.12' }
];

const PLAN_STEPS = [
  { id: 'inspect', title: '检查认证状态与会话恢复逻辑', status: 'completed' },
  { id: 'trace', title: '定位跨标签页状态不同步的原因', status: 'completed' },
  { id: 'patch', title: '更新认证 Store 并添加回归测试', status: 'active' },
  { id: 'verify', title: '运行测试并在浏览器中验证', status: 'pending' }
] as const;

const CHANGES = [
  { path: 'src/features/auth/auth-store.ts', added: 18, removed: 4 },
  { path: 'src/features/auth/auth-store.test.ts', added: 36, removed: 0 },
  { path: 'src/app/session-bridge.ts', added: 9, removed: 2 }
];

function Status({ status }: { status: SessionItem['status'] }) {
  const icon = status === 'Running' ? <Activity size={12} /> : status === 'Completed' ? <CheckCircle2 size={12} /> : <TimerReset size={12} />;
  return <span className={`status ${status.toLowerCase().replace(' ', '-')}`}>{icon}{status}</span>;
}

function SessionRow({ session, selected, onSelect }: { session: SessionItem; selected: boolean; onSelect: (id: string) => void }) {
  return <button className={`session-row ${selected ? 'selected' : ''}`} onClick={() => onSelect(session.id)} type="button"><span className="session-title"><i className={session.target.toLowerCase()} />{session.title}</span><span className="session-meta"><Status status={session.status} /><span>{session.cost}</span></span></button>;
}

function PlanCard() {
  return <section className="plan-card"><div className="card-title"><span><Sparkles size={15} />执行计划</span><button type="button">编辑</button></div><ol>{PLAN_STEPS.map((step, index) => <li key={step.id} className={step.status}><span className="step-index">{step.status === 'completed' ? <CheckCircle2 size={14} /> : index + 1}</span><span>{step.title}</span>{step.status === 'active' && <b>进行中</b>}</li>)}</ol></section>;
}

function ActivityFeed() {
  const source = '  42  channel.onmessage = ({ data }) => {\n  43    if (data.type === \'session:update\') {\n  44      setSession(data.session)\n  45    }\n  46  }';
  return <section className="activity-feed"><div className="assistant-message"><span className="avatar"><Bot size={17} /></span><div><p>我已经确认问题出在跨标签页的 session 更新没有回写到 auth store。</p><p>现在正在更新 Store，并补充回归测试。完成后我会运行测试并打开本地预览验证。</p></div></div><div className="tool-card"><div><FileCode2 size={15} />read_file <span>src/features/auth/auth-store.ts</span><CheckCircle2 size={15} /></div><pre>{source}</pre></div><div className="tool-card active-tool"><div><Wrench size={15} />apply_patch <span>2 个文件</span><b>正在执行</b></div><i /></div></section>;
}

function ChangesPanel() {
  const diff = '−  setSession(data.session)\n+  persistSession(data.session)\n+  broadcastSession(data.session)';
  return <div className="changes-panel"><div className="change-summary"><span><b>+63</b><em>−6</em></span><button type="button">查看全部 Diff</button></div>{CHANGES.map((change) => <button className="change-row" type="button" key={change.path}><FileCode2 size={15} /><span>{change.path}</span><b>+{change.added}</b><em>−{change.removed}</em></button>)}<div className="diff-preview"><div>auth-store.ts <span>未保存的 Agent 修改</span></div><pre>{diff}</pre><button type="button"><ShieldCheck size={15} />请求代码审查</button></div></div>;
}

function FilesPanel() {
  return <div className="files-panel"><div>web-client <span>⌄</span></div>{['src', '  app', '  features', '    auth', '      auth-store.ts', '      auth-store.test.ts', 'package.json'].map((entry) => <button key={entry} type="button" className={entry.includes('auth-store.ts') ? 'active-file' : ''}><FileCode2 size={14} />{entry}</button>)}</div>;
}

function BrowserPanel() {
  return <div className="browser-panel"><div className="browser-address"><Globe2 size={14} /><span>http://localhost:5173/login</span><b>● Live</b></div><div className="browser-canvas"><div className="mock-login"><strong>⌘</strong><h3>Welcome back</h3><p>Sign in to continue to your workspace</p><input value="developer@example.com" readOnly /><button type="button">Continue</button><small><CheckCircle2 size={13} />Session restored</small></div></div><p><CheckCircle2 size={13} />DOM snapshot captured</p><p><CheckCircle2 size={13} />No console errors</p></div>;
}

function ReviewPanel() {
  return <div className="review-panel"><ShieldCheck size={30} /><h3>等待变更稳定</h3><p>Agent 完成当前补丁后，可启动只读 Review Worker 审查正确性、安全性和测试缺口。</p><button type="button">开始审查</button></div>;
}

interface ProviderDraft {
  id: string;
  name: string;
  baseUrl: string;
  protocol: 'openai-compatible' | 'anthropic-compatible';
  model: string;
  apiKey: string;
}

const DEFAULT_PROVIDER: ProviderDraft = {
  id: 'deepseek-default',
  name: 'DeepSeek 官方',
  baseUrl: 'https://api.deepseek.com/v1/',
  protocol: 'openai-compatible',
  model: 'deepseek-chat',
  apiKey: ''
};

function ProviderSettings({ onClose }: { onClose: () => void }) {
  const [draft, setDraft] = useState<ProviderDraft>(DEFAULT_PROVIDER);
  const [status, setStatus] = useState<string>('');
  const bridge = typeof window !== 'undefined' ? window.deepseekCode : undefined;

  const update = <K extends keyof ProviderDraft>(key: K, value: ProviderDraft[K]) => {
    setDraft((current) => ({ ...current, [key]: value }));
    setStatus('');
  };

  const save = async () => {
    if (!draft.baseUrl.trim() || !draft.model.trim()) {
      setStatus('请填写 Base URL 和模型');
      return;
    }
    await bridge?.providers?.save(draft);
    setStatus('已安全保存到本机 Keychain');
  };

  const testConnection = async () => {
    setStatus('正在测试连接…');
    try {
      const result = await bridge?.providers?.test({ ...draft });
      setStatus(result?.ok === false ? `连接失败：${result.error}` : '连接成功');
    } catch (error) {
      setStatus(`连接失败：${error instanceof Error ? error.message : String(error)}`);
    }
  };

  return <div className="settings-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <section className="settings-modal" role="dialog" aria-modal="true" aria-labelledby="provider-settings-title">
      <header><div><p>SETTINGS / PROVIDERS</p><h2 id="provider-settings-title">Provider 设置</h2><small>API Key 只会通过主进程写入 macOS Keychain，不会进入 SQLite 或日志。</small></div><button type="button" aria-label="关闭设置" onClick={onClose}><X size={17} /></button></header>
      <div className="settings-form">
        <label>Provider 名称<input value={draft.name} onChange={(event) => update('name', event.target.value)} /></label>
        <label>Base URL<input aria-label="Base URL" value={draft.baseUrl} onChange={(event) => update('baseUrl', event.target.value)} /></label>
        <div className="settings-grid">
          <label>协议<select value={draft.protocol} onChange={(event) => update('protocol', event.target.value as ProviderDraft['protocol'])}><option value="openai-compatible">OpenAI-compatible</option><option value="anthropic-compatible">Anthropic-compatible</option></select></label>
          <label>模型<input value={draft.model} onChange={(event) => update('model', event.target.value)} /></label>
        </div>
        <label>API Key<input aria-label="API Key" type="password" value={draft.apiKey} onChange={(event) => update('apiKey', event.target.value)} placeholder="sk-…（不会显示已保存值）" autoComplete="off" /></label>
        {status && <p className="settings-status"><CheckCircle size={14} />{status}</p>}
      </div>
      <footer><button type="button" className="secondary-action" onClick={() => void testConnection()}>测试连接</button><span /><button type="button" className="secondary-action" onClick={onClose}>取消</button><button type="button" className="primary-action" onClick={() => void save()}>保存 Provider</button></footer>
    </section>
  </div>;
}

function WorkspacePanel({ panel, onPanelChange }: { panel: RightPanel; onPanelChange: (value: RightPanel) => void }) {
  const panels: Array<[RightPanel, typeof LayoutPanelTop]> = [['Changes', LayoutPanelTop], ['Files', FileCode2], ['Browser', Globe2], ['Review', ShieldCheck]];
  return <aside className="right-panel"><div className="panel-tabs">{panels.map(([name, Icon]) => <button type="button" key={name} onClick={() => onPanelChange(name)} className={panel === name ? 'selected-tab' : ''}><Icon size={14} />{name}</button>)}</div>{panel === 'Changes' ? <ChangesPanel /> : panel === 'Files' ? <FilesPanel /> : panel === 'Browser' ? <BrowserPanel /> : <ReviewPanel />}</aside>;
}

export function App() {
  const [activeSessionId, setActiveSessionId] = useState('login');
  const [mode, setMode] = useState<AgentMode>('Accept Edits');
  const [panel, setPanel] = useState<RightPanel>('Changes');
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [draft, setDraft] = useState('修复登录状态在多个标签页之间不同步的问题，并验证登录页。');
  const [agentStatus, setAgentStatus] = useState('Dev server ready');
  const [projectPath, setProjectPath] = useState('');
  const activeSession = useMemo(() => SESSIONS.find((session) => session.id === activeSessionId) ?? SESSIONS[0]!, [activeSessionId]);
  const projectName = projectPath.split('/').filter(Boolean).at(-1) ?? 'web-client';
  const chooseProject = async () => {
    const bridge = typeof window !== 'undefined' ? window.deepseekCode : undefined;
    const selected = await bridge?.projects.chooseFolder();
    if (selected) {
      setProjectPath(selected);
      setAgentStatus('项目已打开，等待任务');
    }
  };
  const runTask = async () => {
    const bridge = typeof window !== 'undefined' ? window.deepseekCode : undefined;
    if (!bridge?.agent) {
      setAgentStatus('桌面 Agent 服务不可用');
      return;
    }
    setAgentStatus('Agent 正在准备任务…');
    try {
      const result = await bridge.agent.run({
        sessionId: activeSession.id,
        projectPath: projectPath || '.',
        prompt: draft,
        providerProfileId: 'deepseek-default',
        mode: mode.toLowerCase().replace(' ', '_')
      });
      setAgentStatus(result.status === 'waiting_approval' ? '等待你的审批' : 'Agent 已完成本轮');
    } catch (error) {
      setAgentStatus(`Agent 失败：${error instanceof Error ? error.message : String(error)}`);
    }
  };
  return <><main className="app-shell"><aside className="sidebar"><div className="brand"><span><Code2 size={19} /></span><h1>DeepSeek Code</h1><button type="button" aria-label="项目菜单"><ChevronDown size={15} /></button></div><button type="button" className="project-switcher" aria-label="打开项目" onClick={() => void chooseProject()}><i>W</i><span><b>{projectName}</b><small>{projectPath || '点击选择本地仓库'}</small></span><MoreHorizontal size={16} /></button><nav><button className="active-nav" type="button"><LayoutPanelTop size={16} />Projects</button><button type="button"><TerminalSquare size={16} />Sessions <b>4</b></button><button type="button"><TimerReset size={16} />Scheduled</button><button type="button"><Sparkles size={16} />Skills</button><button type="button"><Wrench size={16} />MCP</button><button type="button"><Activity size={16} />Usage</button></nav><div className="sessions-heading"><span>RECENT SESSIONS</span><button type="button" aria-label="新建会话"><Plus size={16} /></button></div><div className="session-list">{SESSIONS.map((session) => <SessionRow key={session.id} session={session} selected={session.id === activeSessionId} onSelect={setActiveSessionId} />)}</div><footer><button type="button" onClick={() => setSettingsOpen(true)}><Settings2 size={16} />Settings</button><span><i />本地优先 · 已加密</span></footer></aside><section className="conversation"><header><div><p><span>{projectName}</span> / Sessions</p><h2>{activeSession?.title}</h2><small><span><GitBranch size={13} />{activeSession?.branch}</span><b>{activeSession?.target}</b><b>12.4K / 128K</b></small></div><div className="header-actions"><button type="button" aria-label="搜索会话"><Search size={17} /></button><button type="button" aria-label="更多操作"><MoreHorizontal size={18} /></button></div></header><div className="conversation-body"><PlanCard /><ActivityFeed /></div><div className="composer"><div><div className="mode-switcher">{(['Plan', 'Manual', 'Accept Edits', 'Auto'] as AgentMode[]).map((item) => <button type="button" aria-pressed={mode === item} className={mode === item ? 'mode-active' : ''} key={item} onClick={() => setMode(item)}>{item}</button>)}</div><button type="button" className="model-picker">DeepSeek V4 Pro<ChevronDown size={13} /></button></div><section><textarea value={draft} onChange={(event) => setDraft(event.target.value)} aria-label="任务描述" /><footer><button type="button">@ 添加上下文</button><span>预计 ¥0.03 <button type="button" aria-label="发送任务" onClick={() => void runTask()}><Play size={15} fill="currentColor" /></button></span></footer></section></div></section><WorkspacePanel panel={panel} onPanelChange={setPanel} /><div className="bottom-bar"><span><TerminalSquare size={14} />Terminal</span><span><PanelBottom size={14} />Problems <b>0</b></span><span><Activity size={14} />Output</span><span><i />{agentStatus}</span></div></main>{settingsOpen && <ProviderSettings onClose={() => setSettingsOpen(false)} />}</>;
}
