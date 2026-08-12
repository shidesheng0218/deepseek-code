// @vitest-environment jsdom
import '@testing-library/jest-dom/vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, test, vi } from 'vitest';
import { App } from '../../src/renderer/App';

afterEach(() => cleanup());

describe('provider settings', () => {
  test('saves provider configuration through the protected desktop bridge', async () => {
    const save = vi.fn().mockResolvedValue({ id: 'deepseek-default' });
    window.deepseekCode = { providers: { list: vi.fn().mockResolvedValue([]), save, test: vi.fn() } } as never;

    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }));
    fireEvent.change(screen.getByLabelText('API Key'), { target: { value: 'sk-test' } });
    fireEvent.click(screen.getByRole('button', { name: '保存 Provider' }));

    expect(save).toHaveBeenCalledWith(expect.objectContaining({
      baseUrl: 'https://api.deepseek.com/v1/',
      apiKey: 'sk-test'
    }));
  });

  test('opens a local provider settings panel from the workspace shell', () => {
    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }));

    expect(screen.getByRole('heading', { name: 'Provider 设置' })).toBeInTheDocument();
    expect(screen.getByLabelText('Base URL')).toHaveValue('https://api.deepseek.com/v1/');
    expect(screen.getByLabelText('API Key')).toHaveAttribute('type', 'password');
  });
});
