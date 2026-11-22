#!/usr/bin/env node
/**
 * 局域网商店服务：静态托管 store/，设备与 PC 同网段直接访问。
 *
 * 用法：
 *   node tools/serve.mjs --port 8787 --store store
 *   node tools/serve.mjs --port 8787 --pin 123456          # 设备需带 X-Store-Pin
 *   node tools/serve.mjs --port 8787 --host 0.0.0.0
 *
 * 设备侧地址：http://<PC-IP>:8787/index.json 或 /api/index
 */
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  args: process.argv.slice(2),
  options: {
    port: { type: 'string', default: '8787' },
    host: { type: 'string', default: '0.0.0.0' },
    store: { type: 'string', default: 'store' },
    pin: { type: 'string', default: '' },
  },
});

const root = path.resolve(values.store);
const pin = values.pin;
const port = Number(values.port);

const MIME = {
  '.json': 'application/json; charset=utf-8',
  '.hap': 'application/octet-stream',
  '.png': 'image/png',
  '.md': 'text/markdown; charset=utf-8',
};

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(data),
    'access-control-allow-origin': '*',
  });
  res.end(data);
}

function authorized(req, url) {
  if (!pin) return true;
  const header = req.headers['x-store-pin'];
  const query = url.searchParams.get('pin');
  return header === pin || query === pin;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    sendJson(res, 405, { error: 'method_not_allowed' });
    return;
  }
  if (!authorized(req, url)) {
    sendJson(res, 401, { error: 'pin_required' });
    return;
  }

  const rel = url.pathname === '/api/index' ? 'index.json'
    : url.pathname.replace(/^\/+/, '');
  if (!rel || rel.includes('..') || path.isAbsolute(rel)) {
    sendJson(res, 400, { error: 'bad_path' });
    return;
  }

  const file = path.join(root, rel);
  let info;
  try {
    info = await stat(file);
  } catch {
    sendJson(res, 404, { error: 'not_found', path: rel });
    return;
  }
  if (!info.isFile()) {
    sendJson(res, 404, { error: 'not_found', path: rel });
    return;
  }

  // Range：大 HAP 断点续传
  const mime = MIME[path.extname(file).toLowerCase()] ?? 'application/octet-stream';
  const range = req.headers.range;
  if (range) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!m) { sendJson(res, 416, { error: 'bad_range' }); return; }
    const start = m[1] === '' ? 0 : Number(m[1]);
    const end = m[2] === '' ? info.size - 1 : Number(m[2]);
    if (start > end || end >= info.size) { sendJson(res, 416, { error: 'bad_range' }); return; }
    res.writeHead(206, {
      'content-type': mime,
      'content-length': end - start + 1,
      'content-range': `bytes ${start}-${end}/${info.size}`,
      'accept-ranges': 'bytes',
      'access-control-allow-origin': '*',
    });
    if (req.method === 'HEAD') { res.end(); return; }
    createReadStream(file, { start, end }).pipe(res);
    return;
  }

  res.writeHead(200, {
    'content-type': mime,
    'content-length': info.size,
    'accept-ranges': 'bytes',
    'access-control-allow-origin': '*',
    'cache-control': 'no-cache',
  });
  if (req.method === 'HEAD') { res.end(); return; }
  createReadStream(file).pipe(res);
});

server.listen(port, values.host, () => {
  const shown = values.host === '0.0.0.0' ? '<本机局域网 IP>' : values.host;
  console.log(`[serve] store=${root}`);
  console.log(`[serve] http://${shown}:${port}/index.json${pin ? '（需要 X-Store-Pin）' : ''}`);
});
