/** 计算 part/total 的百分比（0~100，保留整数）。 */
export function percentage(part, total) {
  return Math.round((part / total) * 100);
}
