/** 结构检查：a.js 与 b.js 之间不再有直接互相 import。 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const srcDir = new URL('../src', import.meta.url).pathname;
const a = readFileSync(join(srcDir, 'a.js'), 'utf8');
const b = readFileSync(join(srcDir, 'b.js'), 'utf8');
const aImportsB = /from\s+['"]\.\/b\.js['"]/.test(a);
const bImportsA = /from\s+['"]\.\/a\.js['"]/.test(b);
if (aImportsB && bImportsA) {
  console.error('a.js 与 b.js 仍互相 import');
  process.exit(1);
}
console.log('结构检查通过');
