import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  ReadyError, buildResult, parseInstallResult, parseReadyList, parseReadyMeta, remoteBaseName, verifyFile,
} from '../lib/agent-lib.mjs';

const goodMeta = {
  id: 'req-20261122-0001',
  bundleName: 'com.local.homekiosk',
  versionCode: 1000000,
  versionName: '1.0.0',
  hap: 'entry-signed.hap',
  sizeBytes: 12,
  sha256: 'a'.repeat(64),
  requestedAt: '2026-11-22T00:00:00Z',
};

test('parseReadyList 去重并过滤非 json', () => {
  const out = parseReadyList('a.json\r\na.json\nnotes.txt\nsub/b.json\n');
  assert.deepEqual(out, ['a.json', 'b.json']);
});

test('remoteBaseName 兼容正反斜杠', () => {
  assert.equal(remoteBaseName('/x/y/z.hap'), 'z.hap');
  assert.equal(remoteBaseName('x\\y\\z.hap'), 'z.hap');
  assert.equal(remoteBaseName(''), '');
});

test('parseReadyMeta 接受合法元数据', () => {
  const meta = parseReadyMeta(JSON.stringify(goodMeta));
  assert.equal(meta.bundleName, 'com.local.homekiosk');
  assert.equal(meta.hap, 'entry-signed.hap');
});

test('parseReadyMeta 拒绝非法输入', () => {
  assert.throws(() => parseReadyMeta('not json'), ReadyError);
  assert.throws(() => parseReadyMeta(JSON.stringify({ ...goodMeta, id: 'x' })), /id 非法/);
  assert.throws(() => parseReadyMeta(JSON.stringify({ ...goodMeta, sha256: 'abc' })), /sha256 非法/);
  assert.throws(() => parseReadyMeta(JSON.stringify({ ...goodMeta, hap: 'x.apk' })), /hap 文件名非法/);
  assert.throws(() => parseReadyMeta(JSON.stringify({ ...goodMeta, bundleName: '../evil' })), /bundleName 非法/);
});

test('parseInstallResult 判定成功与失败', () => {
  assert.equal(parseInstallResult('install bundle successfully.', 0).ok, true);
  assert.equal(parseInstallResult('error: failed to install', 1).ok, false);
  assert.equal(parseInstallResult('install bundle successfully.', 1).ok, false);
});

test('verifyFile 比对 sha256', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'agent-hash-'));
  try {
    const f = path.join(dir, 'abc.bin');
    await writeFile(f, 'abc');
    const expected = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
    assert.equal((await verifyFile(f, expected)).ok, true);
    assert.equal((await verifyFile(f, expected.toUpperCase())).ok, true);
    assert.equal((await verifyFile(f, 'b'.repeat(64))).ok, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('buildResult 字段完整', () => {
  const meta = parseReadyMeta(JSON.stringify(goodMeta));
  const r = buildResult({ meta, status: 'installed', installedAt: '2026-11-22T00:00:00Z' });
  assert.equal(r.id, goodMeta.id);
  assert.equal(r.status, 'installed');
  assert.equal(r.sha256, goodMeta.sha256);
});
