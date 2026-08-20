import { test } from 'node:test';
import assert from 'node:assert/strict';
import { invoiceCode } from '../src/invoice.js';
import { reportName } from '../src/report.js';

test('发票编码补零', () => {
  assert.equal(invoiceCode(2026, 3, 7), 'INV-202603-07');
});

test('日报名称补零', () => {
  assert.equal(reportName(2026, 8, 5), '日报-2026年08月05日');
});
