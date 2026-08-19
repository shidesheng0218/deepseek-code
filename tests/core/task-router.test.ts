import { describe, expect, test } from 'vitest';
import { classifyTask, isSimpleDirectAnswer } from '../../src/core/task-router';

describe('task router', () => {
  test('routes simple questions to a fast direct answer', () => {
    const result = classifyTask('TypeScript 里 unknown 和 any 有什么区别？');
    expect(result.route).toBe('direct_answer');
    expect(result.tier).toBe('fast');
    expect(isSimpleDirectAnswer('TypeScript 里 unknown 和 any 有什么区别？')).toBe(true);
  });

  test('keeps project questions local instead of triggering web research', () => {
    expect(classifyTask('当前项目使用了什么状态管理方案？').route).toBe('project_question');
    expect(classifyTask('探索当前仓库的构建入口').route).toBe('exploration');
    expect(classifyTask('这个项目的构建入口在哪').route).toBe('project_question');
  });

  test('requires explicit realtime intent for web research', () => {
    expect(classifyTask('查一下今天的天气').route).toBe('web_research');
    expect(classifyTask('搜索 React 官方文档的 useEffect').route).toBe('web_research');
    expect(classifyTask('什么是闭包').route).toBe('direct_answer');
  });

  test('routes code changes and CI repair to the capable tier', () => {
    expect(classifyTask('修复登录状态不同步的问题').route).toBe('code_change');
    expect(classifyTask('CI 构建失败了，帮我看看').route).toBe('ci_repair');
    expect(classifyTask('修复登录状态不同步的问题').tier).toBe('capable');
  });
});
