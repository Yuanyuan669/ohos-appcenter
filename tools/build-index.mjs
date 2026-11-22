#!/usr/bin/env node
/**
 * 生成 store/index.json。
 *
 * 用法：
 *   node tools/build-index.mjs --store store --base-url http://192.168.x.x:8787
 *   node tools/build-index.mjs --store store --channel beta --dry-run
 */
import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { buildIndex, validateIndex } from './lib/index-lib.mjs';

const args = process.argv.slice(2);
const { values } = parseArgs({
  args,
  options: {
    store: { type: 'string', default: 'store' },
    'base-url': { type: 'string', default: '' },
    channel: { type: 'string', default: 'stable' },
    'min-app-version-code': { type: 'string', default: '1' },
    out: { type: 'string', default: '' },
    'dry-run': { type: 'boolean', default: false },
  },
});

const storeDir = path.resolve(values.store);
const outFile = values.out ? path.resolve(values.out) : path.join(storeDir, 'index.json');

const index = await buildIndex(path.join(storeDir, 'apps'), {
  channel: values.channel,
  baseUrl: values['base-url'],
  minAppVersionCode: Number(values['min-app-version-code']),
});

const check = await validateIndex(index, { storeDir, verifyFiles: true });
if (!check.ok) {
  console.error('[build-index] 生成后自检失败：');
  for (const e of check.errors) console.error('  - ' + e);
  process.exit(1);
}

const text = JSON.stringify(index, null, 2) + '\n';
if (values['dry-run']) {
  process.stdout.write(text);
} else {
  await writeFile(outFile, text, 'utf8');
  console.log(`[build-index] ${index.apps.length} 个应用 -> ${outFile}`);
}
