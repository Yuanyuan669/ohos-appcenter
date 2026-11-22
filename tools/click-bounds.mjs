#!/usr/bin/env node
/**
 * 从 uitest dumpLayout 的 JSON 里找出第 N 个「下载/重试」按钮的中心坐标。
 * uitest 只能点坐标，不能按 selector 点，所以先 dump 再算。
 *
 * 用法：
 *   node tools/click-bounds.mjs <layout.json> [index]
 *
 * 输出：`<x> <y>`；找不到时非 0 退出。
 */
import { readFileSync } from 'node:fs';

const file = process.argv[2];
const want = Number(process.argv[3] ?? 0);
if (!file) {
  console.error('用法: node tools/click-bounds.mjs <layout.json> [index]');
  process.exit(2);
}

const doc = JSON.parse(readFileSync(file, 'utf8'));

const hits = [];
function walk(node) {
  if (!node) return;
  const a = node.attributes || {};
  if (a.type === 'Button' && ['下载', '重试'].includes(a.text) && a.bounds) {
    const m = a.bounds.match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
    if (m) {
      const [, x1, y1, x2, y2] = m.map(Number);
      hits.push({ text: a.text, x: Math.round((x1 + x2) / 2), y: Math.round((y1 + y2) / 2) });
    }
  }
  (node.children || []).forEach(walk);
}
walk(doc);

const hit = hits[want];
if (!hit) {
  console.error(`没有第 ${want} 个「下载/重试」按钮（共 ${hits.length} 个）`);
  process.exit(1);
}
console.log(`${hit.x} ${hit.y}`);
