import { test } from 'node:test';
import assert from 'node:assert/strict';
import { toCsv } from '../src/csv.js';

test('普通行不需要引号', () => {
  assert.equal(toCsv([['a', 'b', 'c']]), 'a,b,c');
});

test('包含逗号的单元格加引号', () => {
  assert.equal(toCsv([['a,b', 'c']]), '"a,b",c');
});

test('包含引号的单元格双写转义', () => {
  assert.equal(toCsv([['说 "你好"', 'x']]), '"说 ""你好""",x');
});

test('包含换行的单元格加引号保留换行', () => {
  assert.equal(toCsv([['第一行\n第二行', 42]]), '"第一行\n第二行",42');
});

test('多行与数字混合', () => {
  assert.equal(toCsv([['h1', 'h2'], [1, 'x,y']]), 'h1,h2\n1,"x,y"');
});
