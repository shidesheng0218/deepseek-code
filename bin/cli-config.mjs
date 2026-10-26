/**
 * 分层配置：命令行 > 环境变量 > 项目 .deepseek/config.json > 用户 ~/.deepseek/config.json。
 * 凭据不写入配置文件——apiKey 只来自环境变量或系统钥匙串。
 */
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const KNOWN_KEYS = {
  baseURL: 'baseURL',
  model: 'model',
  protocol: 'protocol',
  mode: 'mode',
  fastModel: 'fastModel',
  sessionRoot: 'sessionRoot',
  browserRuntimeDir: 'browserRuntimeDir',
};

const ENV_MAP = {
  baseURL: 'DEEPSEEK_BASE_URL',
  model: 'DEEPSEEK_MODEL',
  protocol: 'DEEPSEEK_PROTOCOL',
  mode: 'DEEPSEEK_MODE',
  fastModel: 'DEEPSEEK_FAST_MODEL',
  sessionRoot: 'DEEPSEEK_SESSION_ROOT',
  browserRuntimeDir: 'DEEPSEEK_BROWSER_RUNTIME_DIR',
};

const VALID_MODES = new Set(['plan', 'manual', 'accept_edits', 'auto']);
const VALID_PROTOCOLS = new Set(['openai-compatible', 'anthropic-messages']);

async function readJsonFile(file) {
  try {
    const parsed = JSON.parse(await readFile(file, 'utf8'));
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

async function writeJsonFile(file, values) {
  await mkdir(join(file, '..'), { recursive: true });
  await writeFile(file, JSON.stringify(values, null, 2) + '\n', { mode: 0o600 });
}

export function userConfigPath(env = process.env) {
  const home = env.HOME || env.USERPROFILE || '.';
  return process.platform === 'win32'
    ? join(env.APPDATA || join(home, 'AppData', 'Roaming'), 'DeepSeekCode', 'config.json')
    : join(env.XDG_CONFIG_HOME || join(home, '.config'), 'deepseek', 'config.json');
}

export function projectConfigPath(projectPath) {
  return join(projectPath, '.deepseek', 'config.json');
}

export function validateConfigValue(key, value) {
  if (!KNOWN_KEYS[key]) throw new Error(`Unknown config key: ${key}. Valid keys: ${Object.keys(KNOWN_KEYS).join(', ')}`);
  const text = String(value).trim();
  if (!text) throw new Error(`Config ${key} must not be empty`);
  if (key === 'mode') {
    const mode = text === 'acceptEdits' ? 'accept_edits' : text;
    if (!VALID_MODES.has(mode)) throw new Error(`Invalid mode: ${text}. Use plan, manual, accept_edits or auto.`);
    return mode;
  }
  if (key === 'protocol' && !VALID_PROTOCOLS.has(text)) throw new Error(`Invalid protocol: ${text}`);
  if (key === 'baseURL' && !/^https?:\/\//.test(text)) throw new Error(`baseURL must start with http:// or https://`);
  return text;
}

/** 读取并合并配置；返回 { values, sources }，source 为 cli|env|project|user|default。 */
export async function loadConfig({ projectPath, env = process.env, overrides = {} }) {
  const user = await readJsonFile(userConfigPath(env));
  const project = projectPath ? await readJsonFile(projectConfigPath(projectPath)) : {};
  const values = {
    baseURL: 'https://api.deepseek.com/v1',
    model: 'deepseek-chat',
    protocol: 'openai-compatible',
    mode: 'auto',
  };
  const sources = Object.fromEntries(Object.keys(values).map((key) => [key, 'default']));
  const apply = (key, value, source) => {
    if (value === undefined || value === null || value === '') return;
    values[key] = key === 'mode' || key === 'protocol' || key === 'baseURL' ? validateConfigValue(key, value) : String(value);
    sources[key] = source;
  };
  for (const key of Object.keys(KNOWN_KEYS)) {
    if (user[key] !== undefined) apply(key, user[key], 'user');
    if (project[key] !== undefined) apply(key, project[key], 'project');
    if (env[ENV_MAP[key]]) apply(key, env[ENV_MAP[key]], 'env');
  }
  if (overrides.baseURL) apply('baseURL', overrides.baseURL, 'cli');
  if (overrides.model) apply('model', overrides.model, 'cli');
  if (overrides.protocol) apply('protocol', overrides.protocol, 'cli');
  if (overrides.mode) apply('mode', overrides.mode, 'cli');
  if (overrides.fastModel) apply('fastModel', overrides.fastModel, 'cli');
  return { values, sources };
}

export async function getConfigKey(key, { projectPath, env = process.env } = {}) {
  if (!KNOWN_KEYS[key]) throw new Error(`Unknown config key: ${key}. Valid keys: ${Object.keys(KNOWN_KEYS).join(', ')}`);
  const { values, sources } = await loadConfig({ projectPath, env });
  return { key, value: values[key], source: sources[key] ?? null };
}

export async function setConfigValue(key, value, { scope = 'user', projectPath = process.cwd(), env = process.env } = {}) {
  const normalized = validateConfigValue(key, value);
  const file = scope === 'project' ? projectConfigPath(projectPath) : userConfigPath(env);
  const current = await readJsonFile(file);
  current[key] = normalized;
  await writeJsonFile(file, current);
  return { file, key, value: normalized, scope };
}

export async function unsetConfigValue(key, { scope = 'user', projectPath = process.cwd(), env = process.env } = {}) {
  if (!KNOWN_KEYS[key]) throw new Error(`Unknown config key: ${key}`);
  const file = scope === 'project' ? projectConfigPath(projectPath) : userConfigPath(env);
  const current = await readJsonFile(file);
  delete current[key];
  await writeJsonFile(file, current);
  return { file, key, scope };
}

export async function listConfig({ projectPath, env = process.env } = {}) {
  const { values, sources } = await loadConfig({ projectPath, env });
  return Object.keys(KNOWN_KEYS).map((key) => ({ key, value: values[key] ?? null, source: sources[key] ?? null }));
}
