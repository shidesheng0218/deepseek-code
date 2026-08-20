/** 每天 hour:minute 运行的任务，返回 from 之后的下一次运行时刻。 */
export function nextRun(from, hour, minute) {
  const next = new Date(from);
  next.setHours(hour, minute, 0, 0);
  return next;
}
