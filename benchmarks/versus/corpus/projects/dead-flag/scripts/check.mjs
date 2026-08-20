/** 结构检查：src/ 下不再出现 LEGACY_MODE。 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const srcDir = new URL('../src', import.meta.url).pathname;
for (const name of readdirSync(srcDir).filter((entry) => entry.endsWith('.js'))) {
  if (readFileSync(join(srcDir, name), 'utf8').includes('LEGACY_MODE')) {
    console.error(`${name} 仍包含 LEGACY_MODE`);
    process.exit(1);
  }
}
console.log('结构检查通过');
