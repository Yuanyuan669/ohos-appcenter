/**
 * 索引库：纯函数，便于测试与 CI 复用。
 * schema 见 docs/INDEX-SPEC.md。
 */
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { promises as fs } from 'node:fs';
import path from 'node:path';

const BUNDLE_RE = /^[a-zA-Z][a-zA-Z0-9._-]{2,}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;

export async function sha256File(filePath) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(filePath)) {
    hash.update(chunk);
  }
  return hash.digest('hex');
}

export function isSafeRelative(rel) {
  if (typeof rel !== 'string' || rel.length === 0) return false;
  if (rel.includes('\\') || rel.includes('\0')) return false;
  if (path.isAbsolute(rel)) return false;
  const parts = rel.split('/');
  return parts.every((p) => p.length > 0 && p !== '.' && p !== '..');
}

async function readJson(filePath) {
  const text = await fs.readFile(filePath, 'utf8');
  return JSON.parse(text);
}

/**
 * 目录约定：store/apps/<bundleName>/<versionCode>/meta.json + 一个 .hap
 * meta.json 必填：name, summary, versionName；可选：category/description/developer/license/source/tags/releaseNotes/minAPIVersion/targetAPIVersion
 */
export async function scanApps(appsDir) {
  const apps = [];
  let bundles = [];
  try {
    bundles = await fs.readdir(appsDir, { withFileTypes: true });
  } catch (err) {
    if (err.code === 'ENOENT') return apps;
    throw err;
  }
  for (const b of bundles) {
    if (!b.isDirectory()) continue;
    if (!BUNDLE_RE.test(b.name)) {
      throw new Error(`非法 bundle 目录名：${b.name}`);
    }
    const bundleDir = path.join(appsDir, b.name);
    const versions = await fs.readdir(bundleDir, { withFileTypes: true });
    for (const v of versions) {
      if (!v.isDirectory()) continue;
      const versionCode = Number(v.name);
      if (!Number.isInteger(versionCode) || versionCode <= 0) {
        throw new Error(`非法 versionCode 目录：${b.name}/${v.name}`);
      }
      const dir = path.join(bundleDir, v.name);
      const files = await fs.readdir(dir);
      const meta = await readJson(path.join(dir, 'meta.json'));
      const haps = files.filter((f) => f.endsWith('.hap'));
      if (haps.length !== 1) {
        throw new Error(`${b.name}/${v.name} 需要恰好一个 .hap，实际 ${haps.length}`);
      }
      const hapPath = path.join(dir, haps[0]);
      const stat = await fs.stat(hapPath);
      apps.push({
        bundleName: b.name,
        versionCode,
        meta,
        hapFile: haps[0],
        hapPath,
        hapRel: `apps/${b.name}/${v.name}/${haps[0]}`,
        sizeBytes: stat.size,
        sha256: await sha256File(hapPath),
      });
    }
  }
  return apps;
}

export async function buildIndex(appsDir, opts = {}) {
  const rows = await scanApps(appsDir);
  const byBundle = new Map();
  for (const row of rows) {
    if (!byBundle.has(row.bundleName)) {
      byBundle.set(row.bundleName, []);
    }
    byBundle.get(row.bundleName).push(row);
  }
  const apps = [];
  for (const [bundleName, versions] of byBundle) {
    versions.sort((a, b) => b.versionCode - a.versionCode);
    const latest = versions[0];
    const meta = latest.meta;
    apps.push({
      bundleName,
      name: meta.name,
      summary: meta.summary,
      description: meta.description ?? '',
      developer: meta.developer ?? 'local',
      license: meta.license ?? '',
      source: meta.source ?? '',
      category: meta.category ?? '其他',
      tags: meta.tags ?? [],
      deviceTypes: meta.deviceTypes ?? ['default', 'phone', 'tablet'],
      latest: {
        versionName: meta.versionName,
        versionCode: latest.versionCode,
        minAPIVersion: meta.minAPIVersion ?? 10,
        targetAPIVersion: meta.targetAPIVersion ?? 11,
        sizeBytes: latest.sizeBytes,
        sha256: latest.sha256,
        hap: latest.hapRel,
        publishedAt: meta.publishedAt ?? null,
        releaseNotes: meta.releaseNotes ?? '',
        installMode: 'hdc',
      },
      versions: versions.map((v) => ({
        versionName: v.meta.versionName,
        versionCode: v.versionCode,
        sizeBytes: v.sizeBytes,
        sha256: v.sha256,
        hap: v.hapRel,
        publishedAt: v.meta.publishedAt ?? null,
      })),
      revoked: false,
    });
  }
  apps.sort((a, b) => a.bundleName.localeCompare(b.bundleName));
  return {
    schemaVersion: 1,
    generatedAt: opts.generatedAt ?? new Date().toISOString(),
    channel: opts.channel ?? 'stable',
    minAppVersionCode: opts.minAppVersionCode ?? 1,
    baseUrl: opts.baseUrl ?? '',
    mirrors: opts.mirrors ?? [
      { id: 'direct', name: '直连', template: '' },
    ],
    apps,
  };
}

/**
 * 校验索引：结构 + 每条 APK/HAP 文件存在且哈希/大小一致。
 * 返回 { ok, errors }，不抛异常（方便 CI 汇总）。
 */
export async function validateIndex(index, { storeDir = null, verifyFiles = true } = {}) {
  const errors = [];
  const push = (msg) => errors.push(msg);

  if (!index || typeof index !== 'object') return { ok: false, errors: ['索引不是对象'] };
  if (index.schemaVersion !== 1) push(`schemaVersion 应为 1，实际 ${index.schemaVersion}`);
  if (typeof index.generatedAt !== 'string' || !index.generatedAt) push('generatedAt 缺失');
  if (!Array.isArray(index.apps)) return { ok: false, errors: [...errors, 'apps 不是数组'] };

  const seenBundles = new Set();
  for (const app of index.apps) {
    const where = app?.bundleName ?? '(未知)';
    if (!app || typeof app !== 'object') { push('apps 含非对象项'); continue; }
    if (!BUNDLE_RE.test(app.bundleName)) push(`${where}: bundleName 非法`);
    if (seenBundles.has(app.bundleName)) push(`${where}: bundleName 重复`);
    seenBundles.add(app.bundleName);
    if (!app.name) push(`${where}: name 缺失`);
    if (!app.summary) push(`${where}: summary 缺失`);
    if (!app.latest || typeof app.latest !== 'object') { push(`${where}: latest 缺失`); continue; }

    const l = app.latest;
    if (!l.versionName) push(`${where}: latest.versionName 缺失`);
    if (!Number.isInteger(l.versionCode) || l.versionCode <= 0) push(`${where}: latest.versionCode 非法`);
    if (!Number.isInteger(l.sizeBytes) || l.sizeBytes <= 0) push(`${where}: latest.sizeBytes 非法`);
    if (typeof l.sha256 !== 'string' || !SHA256_RE.test(l.sha256)) push(`${where}: latest.sha256 非法`);
    if (!isSafeRelative(l.hap)) { push(`${where}: latest.hap 必须是仓内相对路径`); continue; }
    if (!l.hap.endsWith('.hap')) push(`${where}: latest.hap 不是 .hap`);

    if (verifyFiles && storeDir) {
      const abs = path.join(storeDir, l.hap);
      try {
        const stat = await fs.stat(abs);
        if (stat.size !== l.sizeBytes) push(`${where}: 大小不一致（索引 ${l.sizeBytes} / 实际 ${stat.size}）`);
        const hash = await sha256File(abs);
        if (hash !== l.sha256) push(`${where}: sha256 不一致`);
      } catch (err) {
        push(`${where}: HAP 不存在 ${l.hap}（${err.code ?? err.message}）`);
      }
    }

    if (Array.isArray(app.versions)) {
      const codes = app.versions.map((v) => v.versionCode);
      if (codes.some((c) => !Number.isInteger(c) || c <= 0)) push(`${where}: versions 含非法 versionCode`);
      if ([...codes].sort((a, b) => b - a).join(',') !== codes.join(',')) push(`${where}: versions 未按版本降序`);
      if (codes[0] !== l.versionCode) push(`${where}: versions[0] 应等于 latest.versionCode`);
    }
  }
  return { ok: errors.length === 0, errors };
}
