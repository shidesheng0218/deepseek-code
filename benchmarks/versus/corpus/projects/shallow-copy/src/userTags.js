/** 返回一个追加了 tag 的用户副本；不修改传入对象。 */
export function addTag(user, tag) {
  const copy = { ...user };
  copy.tags.push(tag);
  return copy;
}
