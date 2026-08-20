/** 深比较两个值是否相等。 */
export function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}
