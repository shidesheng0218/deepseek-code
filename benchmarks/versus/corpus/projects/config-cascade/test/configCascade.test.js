import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveConfig } from '../src/configCascade.js';

const defaults = { port: 3000, host: 'localhost', debug: false };

test('环境变量优先于配置文件', () => {
  assert.equal(resolveConfig(defaults, { port: 8080 }, { port: 9090 }).port, 9090);
});

test('配置文件覆盖默认值', () => {
  assert.equal(resolveConfig(defaults, { port: 8080 }, {}).port, 8080);
});

test('未覆盖字段回落到默认值', () => {
  assert.equal(resolveConfig(defaults, {}, {}).host, 'localhost');
});
