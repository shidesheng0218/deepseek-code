/** 按 a.b.c 路径从对象深层取值。 */
export function getDeep(object, path) {
  return path.split('.').reduce((value, key) => value[key], object);
}
