/**
 * 按 id 列表汇总报表行。fetcher(id) 返回 Promise<{ id, total }>。
 * 契约：返回全部行，且顺序与 ids 一致。
 */
export async function loadReport(ids, fetcher) {
  const rows = [];
  ids.forEach(async (id) => {
    rows.push(await fetcher(id));
  });
  return rows;
}
