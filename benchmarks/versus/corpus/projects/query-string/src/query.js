/** 把参数对象拼成查询串（不带前导问号）。 */
export function buildQuery(params) {
  return Object.entries(params)
    .map(([key, value]) => `${key}=${value}`)
    .join('&');
}
