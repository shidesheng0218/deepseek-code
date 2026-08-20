/** 结构检查：src/parse.js 存在且 god.js 从它导入解析函数。 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const srcDir = new URL('../src', import.meta.url).pathname;
if (!existsSync(join(srcDir, 'parse.js'))) {
  console.error('src/parse.js 不存在');
  process.exit(1);
}
const god = readFileSync(join(srcDir, 'god.js'), 'utf8');
if (!/from\s+['"]\.\/parse\.js['"]/.test(god)) {
  console.error('god.js 未从 ./parse.js 导入');
  process.exit(1);
}
if (/export function parseBool|export function parseNumber/.test(god)) {
  console.error('god.js 仍直接定义解析函数');
  process.exit(1);
}
console.log('结构检查通过');
