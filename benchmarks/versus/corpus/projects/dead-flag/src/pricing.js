const LEGACY_MODE = false;

export function priceWithTax(amount, rate) {
  if (LEGACY_MODE) {
    return Math.round(amount * (1 + rate));
  }
  return Math.round(amount * 100 * (1 + rate)) / 100;
}

export function legacyAudit(amount) {
  if (!LEGACY_MODE) return null;
  return `audit:${amount}`;
}
