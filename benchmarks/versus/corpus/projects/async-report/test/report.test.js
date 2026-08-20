import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadReport } from '../src/report.js';

const fetcher = async (id) => ({ id, total: id * 10 });

test('返回所有行且保持输入顺序', async () => {
  const rows = await loadReport([3, 1, 2], fetcher);
  assert.deepEqual(rows.map((row) => row.id), [3, 1, 2]);
  assert.deepEqual(rows.map((row) => row.total), [30, 10, 20]);
});

test('慢速来源也不丢行', async () => {
  const slow = async (id) => { await new Promise((resolve) => setTimeout(resolve, 5)); return { id, total: id }; };
  const rows = await loadReport([1, 2, 3, 4], slow);
  assert.equal(rows.length, 4);
});

test('空列表返回空数组', async () => {
  assert.deepEqual(await loadReport([], fetcher), []);
});
