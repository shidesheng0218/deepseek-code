import { describe, expect, test } from 'vitest';
import { classifyCIFailureLog } from '../../src/core/ci-log-classifier';

describe('CI failure classifier', () => {
  test('classifies common CI failure families', () => {
    expect(classifyCIFailureLog("npm ERR! code ERESOLVE\nCould not resolve dependency").kind).toBe('dependency');
    expect(classifyCIFailureLog("error TS2322: Type 'number' is not assignable to type 'string'").kind).toBe('type');
    expect(classifyCIFailureLog("FAIL src/login.test.ts\nExpected true to be false").kind).toBe('test');
    expect(classifyCIFailureLog("Error: Missing environment variable API_URL").kind).toBe('environment');
    expect(classifyCIFailureLog("Segmentation fault in application code").kind).toBe('code');
  });
});
