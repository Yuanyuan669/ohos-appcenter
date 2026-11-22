import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { buildIndex, isSafeRelative, sha256File, validateIndex } from '../lib/index-lib.mjs';

async function makeStore() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'appcenter-'));
  const appDir = path.join(root, 'apps', 'com.local.homekiosk', '1000000');
  await mkdir(appDir, { recursive: true });
  await writeFile(path.join(appDir, 'meta.json'), JSON.stringify({
    name: 'HomeKiosk', summary: '家庭信息屏', versionName: '1.0.0', category: '工具',
    minAPIVersion: 10, targetAPIVersion: 11, publishedAt: '2026-11-16T00:00:00Z',
  }));
  await writeFile(path.join(appDir, 'entry-signed.hap'), Buffer.from('fake hap bytes'));
  return root;
}

test('buildIndex 汇总版本并计算 sha256/大小', async () => {
  const root = await makeStore();
  try {
    const index = await buildIndex(path.join(root, 'apps'), { generatedAt: '2026-11-22T00:00:00Z' });
    assert.equal(index.schemaVersion, 1);
    assert.equal(index.apps.length, 1);
    const app = index.apps[0];
    assert.equal(app.bundleName, 'com.local.homekiosk');
    assert.equal(app.latest.versionCode, 1000000);
    assert.equal(app.latest.sizeBytes, Buffer.byteLength('fake hap bytes'));
    assert.match(app.latest.sha256, /^[0-9a-f]{64}$/);
    assert.equal(app.latest.hap, 'apps/com.local.homekiosk/1000000/entry-signed.hap');
    const check = await validateIndex(index, { storeDir: root });
    assert.deepEqual(check, { ok: true, errors: [] });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('validateIndex 抓到哈希/大小/文件缺失', async () => {
  const root = await makeStore();
  try {
    const index = await buildIndex(path.join(root, 'apps'));
    index.apps[0].latest.sha256 = 'a'.repeat(64);
    index.apps[0].latest.sizeBytes = 1;
    const bad = await validateIndex(index, { storeDir: root });
    assert.equal(bad.ok, false);
    assert.ok(bad.errors.some((e) => e.includes('大小不一致')));
    assert.ok(bad.errors.some((e) => e.includes('sha256 不一致')));

    index.apps[0].latest.hap = 'apps/missing/1/x.hap';
    const missing = await validateIndex(index, { storeDir: root });
    assert.ok(missing.errors.some((e) => e.includes('HAP 不存在')));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('validateIndex 拒绝重复 bundle 与降序错误', async () => {
  const root = await makeStore();
  try {
    const index = await buildIndex(path.join(root, 'apps'));
    const dup = structuredClone(index);
    dup.apps.push(structuredClone(index.apps[0]));
    const r1 = await validateIndex(dup, { storeDir: root, verifyFiles: false });
    assert.ok(r1.errors.some((e) => e.includes('bundleName 重复')));

    const unsorted = structuredClone(index);
    unsorted.apps[0].versions = [
      { versionCode: 1, versionName: '0.1', sizeBytes: 1, sha256: 'b'.repeat(64), hap: 'apps/x/1/a.hap' },
      { versionCode: 2, versionName: '0.2', sizeBytes: 1, sha256: 'b'.repeat(64), hap: 'apps/x/2/a.hap' },
    ];
    const r2 = await validateIndex(unsorted, { storeDir: root, verifyFiles: false });
    assert.ok(r2.errors.some((e) => e.includes('降序')));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('isSafeRelative 拒绝穿越与绝对路径', () => {
  assert.equal(isSafeRelative('apps/a/1/x.hap'), true);
  assert.equal(isSafeRelative('../etc/passwd'), false);
  assert.equal(isSafeRelative('apps/../../x'), false);
  assert.equal(isSafeRelative('/abs/x.hap'), false);
  assert.equal(isSafeRelative('apps\\a\\x.hap'), false);
  assert.equal(isSafeRelative(''), false);
});

test('sha256File 与实际内容一致', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'appcenter-hash-'));
  try {
    const f = path.join(root, 'a.bin');
    await writeFile(f, 'abc');
    // sha256("abc")
    assert.equal(await sha256File(f), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
