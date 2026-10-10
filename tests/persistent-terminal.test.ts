import { rmSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { PersistentTerminal } from '../src/core/persistent-terminal'

// 这些用例守着 sidecar 的"清理与失败路径"：spawn 失败、shell 提前退出、
// 关闭后的调用。它们过去是杀死整个 runtime 或让调用方永久挂起的地方。
describe('PersistentTerminal 失败与清理路径', () => {
  it('工作目录不存在时构造即抛错，而不是让 spawn 的 ENOENT 变成未捕获异常', () => {
    expect(() => new PersistentTerminal({ cwd: '/nonexistent-deepseek-terminal-dir' }))
      .toThrow(/unavailable/)
  })

  it('工作目录被删除后同样的错误可被调用方捕获', () => {
    const directory = mkdtempSync(join(tmpdir(), 'deepseek-terminal-'))
    rmSync(directory, { recursive: true, force: true })
    expect(() => new PersistentTerminal({ cwd: directory })).toThrow(/unavailable/)
  })

  it('正常执行命令并返回退出码与 stdout', async () => {
    const terminal = new PersistentTerminal({ cwd: tmpdir() })
    try {
      const entry = await terminal.exec('echo hello-terminal')
      expect(entry.exitCode).toBe(0)
      expect(entry.stdout).toContain('hello-terminal')
    } finally {
      await terminal.close()
    }
  })

  it('shell 已退出后 close() 立即返回，而不是永久挂起', async () => {
    const terminal = new PersistentTerminal({ cwd: tmpdir() })
    await expect(terminal.exec('kill -9 $$')).rejects.toThrow(/exited unexpectedly/)
    const started = Date.now()
    await terminal.close()
    expect(Date.now() - started).toBeLessThan(3_000)
  })

  it('close() 之后 exec 明确拒绝，而不是排队等到超时', async () => {
    const terminal = new PersistentTerminal({ cwd: tmpdir() })
    await terminal.close()
    await expect(terminal.exec('echo nope')).rejects.toThrow(/closed/)
  })
})