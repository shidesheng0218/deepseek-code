/** 按 id 去重用户记录：同 id 保留首次出现的那条，保持原顺序。 */
export function dedupeById(users) {
  return [...new Set(users)];
}
