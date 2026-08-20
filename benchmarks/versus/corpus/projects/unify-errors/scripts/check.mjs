/** 结构检查：src/ 下不再有字符串直接抛错。 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const srcDir = new URL('../src', import.meta.url).pathname;
for (const name of readdirSync(srcDir).filter((entry) => entry.endsWith('.js'))) {
  const content = readFileSync(join(srcDir, name), 'utf8');
  if (/throw\s+['"]/.test(content)) {
    console.error(`${name} 仍在 throw 字符串`);
    process.exit(1);
  }
}
console.log('结构检查通过');
