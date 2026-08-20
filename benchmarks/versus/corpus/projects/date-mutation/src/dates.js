/** 日期工具：返回某天 00:00 的新 Date；给 Date 加上指定天数。 */
export function startOfDay(date) {
  date.setHours(0, 0, 0, 0);
  return date;
}

export function addDays(date, days) {
  const next = new Date(date);
  next.setDate(next.getDate() + days);
  return next;
}
