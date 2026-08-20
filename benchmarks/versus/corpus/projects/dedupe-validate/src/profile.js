/** 资料更新：与 register.js 存在一份完全重复的校验逻辑。 */
function validateEntry(entry) {
  if (typeof entry.name !== 'string' || entry.name.trim().length === 0) throw new Error('name is required');
  if (entry.name.trim().length > 40) throw new Error('name is too long');
  if (!Number.isInteger(entry.age) || entry.age < 0 || entry.age > 150) throw new Error('age out of range');
}

export function updateProfile(current, patch) {
  const next = { ...current, ...patch };
  validateEntry(next);
  return { name: next.name.trim(), age: next.age };
}
