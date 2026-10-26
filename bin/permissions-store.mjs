/** 权限规则持久化：审批时选择 always 后写入项目 .deepseek/permissions.json，后续同类工具自动放行。 */
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';

export async function loadPermissionRules(projectPath) {
  try {
    const parsed = JSON.parse(await readFile(join(projectPath, '.deepseek', 'permissions.json'), 'utf8'));
    return Array.isArray(parsed.allow) ? parsed.allow : [];
  } catch { return []; }
}

export async function addPermissionRule(projectPath, tool) {
  const file = join(projectPath, '.deepseek', 'permissions.json');
  const rules = await loadPermissionRules(projectPath);
  if (!rules.includes(tool)) {
    await mkdir(join(projectPath, '.deepseek'), { recursive: true });
    await writeFile(file, JSON.stringify({ allow: [...rules, tool] }, null, 2) + '\n', { mode: 0o600 });
  }
  return rules.length + (rules.includes(tool) ? 0 : 1);
}

export async function removePermissionRule(projectPath, tool) {
  const file = join(projectPath, '.deepseek', 'permissions.json');
  const rules = await loadPermissionRules(projectPath);
  const next = rules.filter((r) => r !== tool);
  await writeFile(file, JSON.stringify({ allow: next }, null, 2) + '\n', { mode: 0o600 });
  return rules.length - next.length;
}

export function isAllowedByRule(rules, tool) {
  return rules.includes(tool) || rules.includes('*');
}
