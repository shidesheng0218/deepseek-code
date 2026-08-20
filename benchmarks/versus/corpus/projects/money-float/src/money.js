/** 金额工具：元为单位，保留两位小数。 */
export function addMoney(a, b) {
  return a + b;
}

export function sumMoney(values) {
  return values.reduce((total, value) => total + value, 0);
}
