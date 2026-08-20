/**
 * 结构检查：重复校验片段在 src/ 下最多出现一次（即已被抽取为共享实现）。
 * 该片段是本次重构的判据标记；行为正确性由 npm test 保证。
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const FRAGMENT = 'entry.name.trim().length === 0';
const srcDir = new URL('../src', import.meta.url).pathname;

let count = 0;
for (const name of readdirSync(srcDir).filter((entry) => entry.endsWith('.js'))) {
  const content = readFileSync(join(srcDir, name), 'utf8');
  count += content.split(FRAGMENT).length - 1;
}

if (count > 1) {
  console.error(`校验片段仍重复出现 ${count} 次（要求 ≤ 1）：请抽取共享校验模块。`);
  process.exit(1);
}
console.log('结构检查通过：校验片段未重复。');
