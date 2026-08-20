/** 把二维数组序列化为 CSV 文本。 */
export function toCsv(rows) {
  return rows.map((row) => row.map((cell) => String(cell)).join(',')).join('\n');
}
