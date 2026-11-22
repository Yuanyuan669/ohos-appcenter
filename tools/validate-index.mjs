#!/usr/bin/env node
/**
 * 校验 store/index.json（不生成、不改文件），CI 与本地都用它。
 *
 * 用法：
 *   node tools/validate-index.mjs --store store
 *   node tools/validate-index.mjs --store store --no-files   # 只校验结构
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { validateIndex } from './lib/index-lib.mjs';

const { values } = parseArgs({
  args: process.argv.slice(2),
  options: {
    store: { type: 'string', default: 'store' },
    index: { type: 'string', default: '' },
    'no-files': { type: 'boolean', default: false },
  },
});

const storeDir = path.resolve(values.store);
const indexFile = values.index ? path.resolve(values.index) : path.join(storeDir, 'index.json');

let index;
try {
  index = JSON.parse(await readFile(indexFile, 'utf8'));
} catch (err) {
  console.error(`[validate-index] 读取失败 ${indexFile}: ${err.message}`);
  process.exit(1);
}

const result = await validateIndex(index, {
  storeDir,
  verifyFiles: !values['no-files'],
});
if (!result.ok) {
  console.error(`[validate-index] ${result.errors.length} 个问题：`);
  for (const e of result.errors) console.error('  - ' + e);
  process.exit(1);
}
console.log(`[validate-index] OK：schema v1，${index.apps.length} 个应用`);
