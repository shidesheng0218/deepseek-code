import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'vitest';
import { loadSkills, resolveSlashSkill, skillPromptBlock } from '../../src/core/skills';

async function writeSkill(root: string, segments: string[], name: string, content: string): Promise<void> {
  const dir = join(root, ...segments, name);
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, 'SKILL.md'), content);
}

describe('skills', () => {
  test('discovers project and user skills, project wins on name conflict', async () => {
    const project = await mkdtemp(join(tmpdir(), 'deepseek-skills-project-'));
    const home = await mkdtemp(join(tmpdir(), 'deepseek-skills-home-'));
    await writeSkill(project, ['.deepseek', 'skills'], 'pdf-report', '---\nname: pdf-report\ndescription: 项目版\n---\n项目正文');
    await writeSkill(home, ['.deepseek', 'skills'], 'pdf-report', '---\nname: pdf-report\ndescription: 用户版\n---\n用户正文');
    await writeSkill(home, ['.claude', 'skills'], 'review', '---\ndescription: 审查代码\n---\n审查正文');

    const skills = await loadSkills(project, home);
    expect(skills.map((skill) => skill.name)).toEqual(['pdf-report', 'review']);
    const pdf = skills.find((skill) => skill.name === 'pdf-report');
    expect(pdf?.description).toBe('项目版');
    expect(pdf?.location).toBe('project');
    expect(pdf?.body).toBe('项目正文');
  });

  test('tolerates missing directories and invalid skill files', async () => {
    const project = await mkdtemp(join(tmpdir(), 'deepseek-skills-project-'));
    const home = await mkdtemp(join(tmpdir(), 'deepseek-skills-home-'));
    const skills = await loadSkills(project, home);
    expect(skills).toEqual([]);
    expect(skillPromptBlock(skills)).toBe('');
  });

  test('resolves explicit slash invocation and injects the skill body', async () => {
    const project = await mkdtemp(join(tmpdir(), 'deepseek-skills-project-'));
    const home = await mkdtemp(join(tmpdir(), 'deepseek-skills-home-'));
    await writeSkill(project, ['.deepseek', 'skills'], 'pdf-report', '---\nname: pdf-report\n---\n生成 PDF 的步骤');
    const skills = await loadSkills(project, home);

    const resolved = resolveSlashSkill('/pdf-report 本月数据', skills);
    expect(resolved.skill?.name).toBe('pdf-report');
    expect(resolved.prompt).toContain('生成 PDF 的步骤');
    expect(resolved.prompt).toContain('本月数据');

    const unknown = resolveSlashSkill('/not-a-skill 内容', skills);
    expect(unknown.skill).toBeUndefined();
    expect(unknown.prompt).toBe('/not-a-skill 内容');

    const plain = resolveSlashSkill('普通提问', skills);
    expect(plain.prompt).toBe('普通提问');
  });

  test('prompt block lists skills without leaking bodies', async () => {
    const project = await mkdtemp(join(tmpdir(), 'deepseek-skills-project-'));
    const home = await mkdtemp(join(tmpdir(), 'deepseek-skills-home-'));
    await writeSkill(project, ['.deepseek', 'skills'], 'review', '---\ndescription: 代码审查\n---\n秘密正文');
    const block = skillPromptBlock(await loadSkills(project, home));
    expect(block).toContain('/review');
    expect(block).toContain('代码审查');
    expect(block).not.toContain('秘密正文');
  });
});
