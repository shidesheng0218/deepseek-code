/** 证件号脱敏：保留前 4 后 4，中间用 * 替换。 */
export function maskIdNumber(id) {
  if (id.length <= 8) return id;
  return `${id.slice(0, 4)}${id.slice(4, -4)}${id.slice(-4)}`;
}
