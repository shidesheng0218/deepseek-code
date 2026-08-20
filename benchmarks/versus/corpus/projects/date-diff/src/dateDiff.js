/** 两个 ISO 日期字符串相差的日历天数（b - a，与时刻无关）。 */
export function dayDiff(a, b) {
  return Math.floor((new Date(b) - new Date(a)) / 86400000);
}
