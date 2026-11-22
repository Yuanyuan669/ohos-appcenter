/**
 * PC agent 的纯逻辑：解析设备侧 ready 请求、校验哈希、拼结果。
 * 与 hdc 调用解耦，方便 node --test 离线跑。
 */
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';

const ID_RE = /^[a-zA-Z0-9_-]{8,64}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;

export class ReadyError extends Error {}

export function remoteBaseName(p) {
  const s = String(p ?? '').trim();
  if (!s) return '';
  const parts = s.replace(/\\/g, '/').split('/');
  return parts[parts.length - 1];
}

/** `ls -1 .../ready/*.json` 的输出 -> 去重后的相对文件名列表 */
export function parseReadyList(stdout) {
  const seen = new Set();
  const out = [];
  for (const line of String(stdout ?? '').split(/\r?\n/)) {
    const name = remoteBaseName(line);
    if (!name || !name.endsWith('.json')) continue;
    if (seen.has(name)) continue;
    seen.add(name);
    out.push(name);
  }
  return out;
}

/**
 * 设备侧 ready/*.json 内容：
 * { id, bundleName, versionCode, versionName, hap, sizeBytes, sha256, requestedAt }
 */
export function parseReadyMeta(text) {
  let obj;
  try {
    obj = JSON.parse(text);
  } catch {
    throw new ReadyError('ready 元数据不是合法 JSON');
  }
  if (!obj || typeof obj !== 'object') throw new ReadyError('ready 元数据不是对象');
  if (typeof obj.id !== 'string' || !ID_RE.test(obj.id)) throw new ReadyError(`id 非法：${obj.id}`);
  if (typeof obj.bundleName !== 'string' || !/^[a-zA-Z][a-zA-Z0-9._-]{2,}$/.test(obj.bundleName)) {
    throw new ReadyError(`bundleName 非法：${obj.bundleName}`);
  }
  if (!Number.isInteger(obj.versionCode) || obj.versionCode <= 0) throw new ReadyError('versionCode 非法');
  if (typeof obj.sha256 !== 'string' || !SHA256_RE.test(obj.sha256)) throw new ReadyError('sha256 非法');
  const hap = remoteBaseName(obj.hap);
  if (!hap.endsWith('.hap')) throw new ReadyError(`hap 文件名非法：${obj.hap}`);
  if (typeof obj.sizeBytes === 'number' && obj.sizeBytes <= 0) throw new ReadyError('sizeBytes 非法');
  return {
    id: obj.id,
    bundleName: obj.bundleName,
    versionCode: obj.versionCode,
    versionName: typeof obj.versionName === 'string' ? obj.versionName : '',
    hap,
    sizeBytes: typeof obj.sizeBytes === 'number' ? obj.sizeBytes : null,
    sha256: obj.sha256,
    requestedAt: typeof obj.requestedAt === 'string' ? obj.requestedAt : null,
  };
}

export async function sha256File(filePath) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(filePath)) hash.update(chunk);
  return hash.digest('hex');
}

/** 返回 { ok, actual }；调用方决定如何上报 */
export async function verifyFile(filePath, expectedSha256) {
  const actual = await sha256File(filePath);
  return { ok: actual === expectedSha256.toLowerCase(), actual };
}

export function buildResult({ meta, status, message, installedAt = null }) {
  return {
    id: meta.id,
    bundleName: meta.bundleName,
    versionCode: meta.versionCode,
    versionName: meta.versionName,
    sha256: meta.sha256,
    status,
    message: message ?? '',
    installedAt,
  };
}

/** hdc install 输出里判定成功 */
export function parseInstallResult(stdout, code) {
  const text = String(stdout ?? '');
  const ok = code === 0 && /install bundle successfully|install successfully|success/i.test(text);
  return { ok, message: text.trim().split(/\r?\n/).filter(Boolean).slice(-3).join(' | ') };
}
