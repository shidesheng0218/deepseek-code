/** 把 value 钳制到 [min, max]。 */
export function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}
