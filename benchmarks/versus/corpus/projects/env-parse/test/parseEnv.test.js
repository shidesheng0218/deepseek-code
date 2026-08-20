import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseEnv } from '../src/parseEnv.js';

test('双引号值保留内部空格并去掉引号', () => {
  assert.deepEqual(parseEnv('GREETING="hello world"'), { GREETING: 'hello world' });
});

test('行内注释（前有空白）被剥离', () => {
  assert.deepEqual(parseEnv('PORT=3000 # 服务端口'), { PORT: '3000' });
});

test('引号内的 # 不是注释', () => {
  assert.deepEqual(parseEnv('TAG="a#b"'), { TAG: 'a#b' });
});

test('整行注释与空行跳过', () => {
  assert.deepEqual(parseEnv('# 注释\n\nA=1'), { A: '1' });
});
