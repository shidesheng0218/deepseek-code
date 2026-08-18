import { describe, expect, test } from 'vitest';
import { classifyToolRequest, decidePermission } from '../../src/core/permissions';

describe('permission policy', () => {
  test('plan mode allows read-only tools and blocks mutations', () => {
    expect(decidePermission({ mode: 'plan', risk: 'L0', mutates: false })).toBe('allow');
    expect(decidePermission({ mode: 'plan', risk: 'L1', mutates: true })).toBe('block');
  });

  test('accept edits allows workspace patches but asks for commands', () => {
    expect(decidePermission({ mode: 'accept_edits', risk: 'L1', mutates: true, tool: 'apply_patch' })).toBe('allow');
    expect(decidePermission({ mode: 'accept_edits', risk: 'L1', mutates: true, tool: 'run_command' })).toBe('ask');
  });

  test('auto mode distinguishes tests, dependency installs, and destructive commands', () => {
    expect(classifyToolRequest({ tool: 'run_command', command: 'npm test' }).risk).toBe('L1');
    expect(classifyToolRequest({ tool: 'run_command', command: 'npm install react' }).risk).toBe('L2');
    expect(classifyToolRequest({ tool: 'run_command', command: 'sudo rm -rf /' }).risk).toBe('L4');
    expect(decidePermission({ mode: 'auto', risk: 'L4', mutates: true, tool: 'run_command' })).toBe('block');
  });

  test('treats dynamic MCP tools as approval-required by default', () => {
    expect(classifyToolRequest({ tool: 'mcp__fixture__write_file' }).risk).toBe('L2');
    expect(decidePermission({ mode: 'auto', risk: 'L2', mutates: true, tool: 'mcp__fixture__write_file' })).toBe('ask');
  });

  test('treats configured SSH execution as approval-required by default', () => {
    expect(classifyToolRequest({ tool: 'ssh_execute' }).risk).toBe('L2');
    expect(decidePermission({ mode: 'auto', risk: 'L2', mutates: true, tool: 'ssh_execute' })).toBe('ask');
  });
});
