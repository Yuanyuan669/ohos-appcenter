#!/usr/bin/env node
/**
 * 商店 PC agent：设备侧应用把「已下载 + 已校验」的 HAP 放进沙箱 ready/，
 * agent 通过 hdc 拉回、复核 SHA256、执行 hdc install -r，并写回 done/ 结果。
 *
 * 设备侧（普通应用）没有任何公开 API 能安装任意 HAP（INSTALL_BUNDLE 需 system_core），
 * 所以安装动作只能在 PC 侧完成。这是本方案的核心约束，不是临时妥协。
 *
 * 用法：
 *   node agent/pc-agent.mjs --once
 *   node agent/pc-agent.mjs --interval 3
 *   node agent/pc-agent.mjs --dry-run --once     # 只打印将执行的动作
 *   node agent/pc-agent.mjs --serial 192.168.1.23:5555 --sandbox /data/app/el2/100/base/com.local.appcenter/haps/entry/files/appcenter
 *
 * 环境变量：OHOS_HDC / OHOS_TOOLS（与其它仓一致）
 */
import { execFile } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import {
  ReadyError,
  buildResult,
  parseInstallResult,
  parseReadyList,
  parseReadyMeta,
  verifyFile,
} from './lib/agent-lib.mjs';

const { values } = parseArgs({
  args: process.argv.slice(2),
  options: {
    hdc: { type: 'string', default: '' },
    serial: { type: 'string', default: '' },
    sandbox: { type: 'string', default: '/data/app/el2/100/base/com.local.appcenter/haps/entry/files/appcenter' },
    interval: { type: 'string', default: '5' },
    once: { type: 'boolean', default: false },
    'dry-run': { type: 'boolean', default: false },
    'work-dir': { type: 'string', default: '' },
    verbose: { type: 'boolean', default: false },
  },
});

const log = (...a) => console.log(`[agent ${new Date().toISOString()}]`, ...a);
const warn = (...a) => console.warn(`[agent ${new Date().toISOString()}]`, ...a);

function resolveHdc() {
  if (values.hdc) return values.hdc;
  if (process.env.OHOS_HDC) return process.env.OHOS_HDC;
  if (process.env.OHOS_TOOLS) {
    return path.join(process.env.OHOS_TOOLS, 'sdk', 'openharmony', 'toolchains', 'hdc.exe');
  }
  return process.platform === 'win32' ? 'hdc.exe' : 'hdc';
}

const HDC = resolveHdc();
const workDir = values['work-dir'] || path.join(os.tmpdir(), 'ohos-appcenter-agent');

function run(args, { timeout = 120000 } = {}) {
  const full = values.serial ? ['-t', values.serial, ...args] : args;
  return new Promise((resolve) => {
    execFile(HDC, full, { timeout, windowsHide: true }, (err, stdout, stderr) => {
      resolve({
        code: err ? (typeof err.code === 'number' ? err.code : 1) : 0,
        stdout: String(stdout ?? ''),
        stderr: String(stderr ?? ''),
        error: err ?? null,
      });
    });
  });
}

async function shell(cmd) {
  return run(['shell', cmd]);
}

async function processReady(name) {
  const remoteJson = `${values.sandbox}/ready/${name}`;
  const cat = await shell(`cat '${remoteJson}'`);
  if (cat.code !== 0) {
    warn(`读取 ${name} 失败：${cat.stderr.trim() || cat.stdout.trim()}`);
    return null;
  }
  let meta;
  try {
    meta = parseReadyMeta(cat.stdout);
  } catch (err) {
    if (!(err instanceof ReadyError)) throw err;
    warn(`${name} 元数据无效：${err.message}`);
    await writeResult(name, {
      id: name.replace(/\.json$/, ''),
      status: 'failed',
      message: `invalid_ready_meta: ${err.message}`,
      installedAt: null,
      bundleName: '',
      versionCode: 0,
      versionName: '',
      sha256: '',
    });
    return { ok: false };
  }

  log(`${meta.bundleName} ${meta.versionName || meta.versionCode} (${name})`);
  const remoteHap = `${values.sandbox}/ready/${meta.hap}`;
  const localHap = path.join(workDir, `${meta.bundleName}-${meta.versionCode}.hap`);
  await mkdir(workDir, { recursive: true });

  if (values['dry-run']) {
    log(`[dry-run] 将拉取 ${remoteHap} -> ${localHap}，校验 sha256 后 hdc install -r`);
    return { ok: true };
  }

  const recv = await run(['file', 'recv', remoteHap, localHap]);
  if (recv.code !== 0) {
    warn(`拉取 HAP 失败：${recv.stderr.trim() || recv.stdout.trim()}`);
    await writeResult(name, buildResult({ meta, status: 'failed', message: 'hap_recv_failed' }));
    return { ok: false };
  }

  const check = await verifyFile(localHap, meta.sha256);
  if (!check.ok) {
    warn(`SHA256 不符：期望 ${meta.sha256} 实际 ${check.actual}`);
    await writeResult(name, buildResult({ meta, status: 'failed', message: `sha256_mismatch actual=${check.actual}` }));
    return { ok: false };
  }

  const inst = await run(['install', '-r', localHap], { timeout: 180000 });
  const parsed = parseInstallResult(inst.stdout + '\n' + inst.stderr, inst.code);
  if (!parsed.ok) {
    warn(`安装失败：${parsed.message}`);
    await writeResult(name, buildResult({ meta, status: 'failed', message: `install_failed: ${parsed.message}` }));
    return { ok: false };
  }

  log(`安装成功：${meta.bundleName}`);
  await writeResult(name, buildResult({
    meta,
    status: 'installed',
    message: parsed.message,
    installedAt: new Date().toISOString(),
  }));

  const cleanup = await shell(`mkdir -p '${values.sandbox}/done' && mv '${remoteJson}' '${values.sandbox}/done/'`);
  if (cleanup.code !== 0) warn(`移动 ready 文件失败：${cleanup.stderr.trim()}`);
  return { ok: true };
}

async function writeResult(readyName, record) {
  const id = record.id || readyName.replace(/\.json$/, '');
  const resultRel = `${id}.result.json`;
  if (values['dry-run']) {
    log(`[dry-run] 将写回 ${values.sandbox}/done/${resultRel}: ${JSON.stringify(record)}`);
    return;
  }
  const local = path.join(workDir, resultRel);
  await mkdir(workDir, { recursive: true });
  await writeFile(local, JSON.stringify(record, null, 2), 'utf8');
  const send = await run([
    'file', 'send', local, `${values.sandbox}/done/${resultRel}`,
  ]);
  if (send.code !== 0) warn(`写回结果失败：${send.stderr.trim() || send.stdout.trim()}`);
}

async function tick() {
  const list = await shell(`ls -1 '${values.sandbox}/ready' 2>/dev/null`);
  if (list.code !== 0) {
    if (values.verbose) warn(`列目录失败：${list.stderr.trim()}`);
    return { seen: 0, ok: 0 };
  }
  const names = parseReadyList(list.stdout);
  let ok = 0;
  for (const name of names) {
    const r = await processReady(name);
    if (r?.ok) ok += 1;
  }
  return { seen: names.length, ok };
}

log(`hdc=${HDC} sandbox=${values.sandbox}${values.serial ? ` serial=${values.serial}` : ''}`);
if (values.once) {
  const r = await tick();
  log(`完成：发现 ${r.seen} 个请求，成功 ${r.ok} 个`);
  process.exit(0);
}

const interval = Math.max(1, Number(values.interval) || 5) * 1000;
for (;;) {
  try {
    const r = await tick();
    if (r.seen) log(`本轮：${r.seen} 个请求，成功 ${r.ok} 个`);
  } catch (err) {
    warn(err?.stack ?? String(err));
  }
  await new Promise((r) => setTimeout(r, interval));
}
