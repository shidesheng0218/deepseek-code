/** 内存分页：page 从 1 开始。 */
export function paginate(items, page, pageSize) {
  const start = (page - 1) * pageSize;
  return {
    page,
    pageSize,
    total: items.length,
    items: items.slice(start, start + pageSize - 1)
  };
}
