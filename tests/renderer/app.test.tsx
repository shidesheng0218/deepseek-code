// @vitest-environment jsdom
import '@testing-library/jest-dom/vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, test, vi } from 'vitest';
import { App } from '../../src/renderer/App';

afterEach(() => cleanup());

describe('workspace shell', () => {
  test('shows a session workspace and lets the user change agent mode', () => {
    render(<App />);

    expect(screen.getByRole('heading', { name: 'DeepSeek Code' })).toBeInTheDocument();
    expect(screen.getAllByText('修复登录状态同步')).toHaveLength(2);
    fireEvent.click(screen.getByRole('button', { name: 'Auto' }));
    expect(screen.getByRole('button', { name: 'Auto' })).toHaveAttribute('aria-pressed', 'true');
  });

  test('sends the composer task to the main-process Agent runtime', () => {
    const run = vi.fn().mockResolvedValue({ status: 'completed', text: '完成' });
    window.deepseekCode = { agent: { run, onEvent: vi.fn() } } as never;
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: '发送任务' }));

    expect(run).toHaveBeenCalledWith(expect.objectContaining({
      prompt: '修复登录状态在多个标签页之间不同步的问题，并验证登录页。',
      mode: 'accept_edits'
    }));
  });

  test('uses the folder selected from the desktop bridge as the Agent workspace', async () => {
    const run = vi.fn().mockResolvedValue({ status: 'completed', text: '完成' });
    window.deepseekCode = {
      agent: { run, onEvent: vi.fn() },
      projects: { chooseFolder: vi.fn().mockResolvedValue('/Users/developer/demo-repo') }
    } as never;
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: '打开项目' }));
    expect(await screen.findByText('/Users/developer/demo-repo')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '发送任务' }));

    expect(run).toHaveBeenCalledWith(expect.objectContaining({ projectPath: '/Users/developer/demo-repo' }));
  });
});
