/**
 * DeepSeek Code 驱动器：与 benchmarks/runner.mjs 相同的 sidecar 协议，
 * 但使用真实 Provider（versus 是同模型对照，不用 mock）。
 *
 * 需要的配置（versus.config.json → harnesses.deepseek）：
 *   protocol / baseURL / model / apiKeyEnv（API Key 只从环境变量读取）
 * 度量来源：
 *   approvals = approval_required 事件数；tokens = usage_recorded 事件求和。
 */
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { repoRoot, which } from './util.mjs';

const sidecarEntry = join(repoRoot, 'apps', 'deepseek-agent-runtime', 'src', 'main.ts');
const bundledBun = join(repoRoot, 'node_modules', '@oven', 'bun-darwin-aarch64', 'bin', 'bun');

export default {
  name: 'deepseek',

  async detect(model) {
    if (!model?.baseURL || !model?.model || !model?.apiKeyEnv) return { ok: false, reason: 'versus.config.json 缺少 deepseek.baseURL/model/apiKeyEnv' };
    if (!process.env[model.apiKeyEnv]) return { ok: false, reason: `环境变量 ${model.apiKeyEnv} 未设置` };
    const bun = await resolveBun();
    if (!bun) return { ok: false, reason: '找不到 bun（仓库内 @oven/bun-darwin-aarch64 或 PATH）' };
    return { ok: true };
  },

  async run({ task, workDir, model, env, timeoutMs, transcriptFile }) {
    const bun = await resolveBun();
    const sessionRoot = mkdtempSync(join(tmpdir(), 'deepseek-versus-sessions-'));
    const sessionID = `versus-${task.id}`;
    const frames = [];
    let responseFrame = null;
    const child = await import('node:child_process').then(({ spawn }) => spawn(bun, [sidecarEntry, '--stdio'], {
      cwd: repoRoot,
      env: { ...(env ?? process.env), DEEPSEEK_SESSION_ROOT: sessionRoot },
      stdio: ['pipe', 'pipe', 'pipe']
    }));
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { stderr += chunk; });

    const finished = new Promise((resolvePromise) => {
      let buffer = '';
      const timer = setTimeout(() => { child.kill('SIGKILL'); }, timeoutMs);
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', (chunk) => {
        buffer += chunk;
        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          if (!line.trim()) continue;
          let frame;
          try { frame = JSON.parse(line); } catch { continue; }
          frames.push(frame);
          if (frame.type === 'response') { clearTimeout(timer); resolvePromise(frame); }
        }
      });
      child.once('exit', () => { clearTimeout(timer); resolvePromise(null); });
    });

    child.stdin.end(`${JSON.stringify({
      id: sessionID,
      method: 'session.run',
      params: {
        sessionID,
        projectPath: workDir,
        prompt: task.prompt,
        baseURL: model.baseURL,
        apiKey: process.env[model.apiKeyEnv],
        model: model.model,
        protocol: model.protocol ?? 'openai-compatible',
        mode: 'auto'
      }
    })}\n`);

    responseFrame = await finished;
    child.kill('SIGTERM');
    const events = frames.filter((frame) => frame.type === 'event').map((frame) => frame.event);
    writeFileSync(transcriptFile, JSON.stringify({ harness: 'deepseek', taskID: task.id, frames, events }, null, 2));

    if (!responseFrame) return { status: 'error', error: `sidecar 未返回 response（stderr 尾部：${stderr.slice(-300)}）`, events };
    if (!responseFrame.ok) return { status: 'error', error: responseFrame.error ?? 'session.run 失败', events };

    const usage = events.filter((event) => event.type === 'usage_recorded');
    return {
      status: 'completed',
      approvals: events.filter((event) => event.type === 'approval_required').length,
      tokens: usage.length === 0 ? null : {
        input: usage.reduce((sum, event) => sum + (event.inputTokens ?? 0), 0),
        output: usage.reduce((sum, event) => sum + (event.outputTokens ?? 0), 0),
        cached: usage.reduce((sum, event) => sum + (event.cachedInputTokens ?? 0), 0)
      },
      costUSD: null,
      events
    };
  }
};

async function resolveBun() {
  try {
    const { existsSync } = await import('node:fs');
    if (existsSync(bundledBun)) return bundledBun;
  } catch { /* fall through to PATH lookup */ }
  return which('bun') ? 'bun' : null;
}
