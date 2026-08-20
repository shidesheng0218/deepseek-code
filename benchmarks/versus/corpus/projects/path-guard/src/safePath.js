import { join } from 'node:path';

/** 把用户输入的相对路径解析到 root 之下；越出 root 必须抛错。 */
export function resolveUnderRoot(root, userPath) {
  const resolved = join(root, userPath);
  if (!resolved.startsWith(root)) throw new Error('path escapes root');
  return resolved;
}
