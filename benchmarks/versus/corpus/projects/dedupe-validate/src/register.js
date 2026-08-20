/** 用户注册：校验后写入内存表。 */
const users = [];

function validateEntry(entry) {
  if (typeof entry.name !== 'string' || entry.name.trim().length === 0) throw new Error('name is required');
  if (entry.name.trim().length > 40) throw new Error('name is too long');
  if (!Number.isInteger(entry.age) || entry.age < 0 || entry.age > 150) throw new Error('age out of range');
}

export function registerUser(entry) {
  validateEntry(entry);
  users.push({ name: entry.name.trim(), age: entry.age });
  return users.at(-1);
}

export function listUsers() {
  return [...users];
}
