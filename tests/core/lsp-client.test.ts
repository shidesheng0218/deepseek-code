import { describe, expect, test } from 'vitest';
import { LanguageServerClient } from '../../src/core/lsp-client';

describe('language server client', () => {
  test('initializes a server, opens a document and returns diagnostics', async () => {
    const server = `
      let buffer = '';
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', (chunk) => { buffer += chunk; while (buffer.includes('\\r\\n\\r\\n')) { const split = buffer.split('\\r\\n\\r\\n'); const header = split.shift(); buffer = split.join('\\r\\n\\r\\n'); const length = Number((header.match(/Content-Length: (\\d+)/i) || [])[1]); const body = buffer.slice(0, length); buffer = buffer.slice(length); const request = JSON.parse(body); if (request.method === 'initialize') reply(request.id, { capabilities: { diagnosticProvider: {} } }); else if (request.method === 'textDocument/diagnostic') reply(request.id, { items: [{ message: 'fixture warning', severity: 2, range: { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } } }] }); } });
      function reply(id, result) { const body = JSON.stringify({ jsonrpc: '2.0', id, result }); process.stdout.write('Content-Length: ' + Buffer.byteLength(body) + '\\r\\n\\r\\n' + body); }
    `;
    const client = new LanguageServerClient({ command: process.execPath, args: ['-e', server], rootPath: process.cwd() });
    try {
      const diagnostics = await client.diagnostics('file:///tmp/fixture.ts', 'const value: string = 1', 'typescript');
      expect(diagnostics[0]?.message).toBe('fixture warning');
    } finally {
      await client.close();
    }
  });
});
