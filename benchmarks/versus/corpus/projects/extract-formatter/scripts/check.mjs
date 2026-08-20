/** 结构检查：padStart(2, '0') 片段在 src/ 下最多出现一次。 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const FRAGMENT = "padStart(2, '0')";
const srcDir = new URL('../src', import.meta.url).pathname;
let count = 0;
for (const name of readdirSync(srcDir).filter((entry) => entry.endsWith('.js'))) {
  count += readFileSync(join(srcDir, name), 'utf8').split(FRAGMENT).length - 1;
}
if (count > 1) {
  console.error(`补零片段仍重复出现 ${count} 次（要求 ≤ 1）`);
  process.exit(1);
}
console.log('结构检查通过');
