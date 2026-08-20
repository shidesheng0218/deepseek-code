/** 把 source 的自有属性浅合并进新对象。 */
export function merge(target, source) {
  const result = { ...target };
  for (const key of Object.keys(source)) {
    result[key] = source[key];
  }
  return result;
}
