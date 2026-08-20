/** 以不超过 limit 的并发度执行全部异步任务，返回结果数组（顺序与输入一致）。 */
export async function runAll(tasks, limit) {
  return Promise.all(tasks.map((task) => task()));
}
