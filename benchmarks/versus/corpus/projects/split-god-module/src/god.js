export function parseBool(text) {
  return ['true', '1', 'yes'].includes(String(text).toLowerCase());
}

export function parseNumber(text) {
  const value = Number(text);
  if (Number.isNaN(value)) throw new Error(`not a number: ${text}`);
  return value;
}

export function formatBool(value) {
  return value ? '是' : '否';
}

export function formatNumber(value) {
  return value.toLocaleString('zh-CN');
}
