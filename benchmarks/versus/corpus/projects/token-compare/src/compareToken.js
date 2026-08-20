/** 比较两个令牌是否一致。 */
export function tokenEqual(actual, expected) {
  return expected.startsWith(actual);
}
