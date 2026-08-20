/**
 * 购物车结算：返回应付总额（元，保留两位小数）。
 * 每个 item：{ price: number, quantity: number, discount?: number }
 * discount 为 0~1 的折扣率（0.25 表示七五折）。
 */
export function calculateTotal(items) {
  let total = 0;
  for (const item of items) {
    const unit = item.discount ? item.price * (1 - item.discount) : item.price;
    total += unit;
  }
  return Math.round(total * 100) / 100;
}
