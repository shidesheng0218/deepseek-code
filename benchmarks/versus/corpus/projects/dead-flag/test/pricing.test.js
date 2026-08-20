import { test } from 'node:test';
import assert from 'node:assert/strict';
import { legacyAudit, priceWithTax } from '../src/pricing.js';

test('含税价保留两位小数', () => {
  assert.equal(priceWithTax(19.99, 0.13), 22.59);
});

test('审计函数在新模式下为空', () => {
  assert.equal(legacyAudit(10), null);
});
