#!/usr/bin/env node
/**
 * 在没有 DevEco/SDK 的机器上做最低限度的工程自检：
 *   - json5 语法（去注释/尾逗号后按 JSON 解析）
 *   - AppScope/app.json5 的 bundleName 合法
 *   - entry 的 main_pages.json 里每个页面文件确实存在
 *   - module.json5 的 mainElement / abilities[].srcEntry 指向的文件存在
 *
 * 这只保证「工程结构没写错」，不保证能编译 —— 真正的构建需要 SDK。
 *
 * 用法：node tools/check-app-json.mjs [--app app]
 */
import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  args: process.argv.slice(2),
  options: { app: { type: 'string', default: 'app' } },
});

const appDir = path.resolve(values.app);
const errors = [];
const oks = [];
const fail = (msg) => errors.push(msg);
const ok = (msg) => oks.push(msg);

/** 去掉 // 与 /* *\/ 注释（跳过字符串内部），再去尾逗号 */
function stripJson5(text) {
  let out = '';
  let i = 0;
  let quote = null;
  while (i < text.length) {
    const c = text[i];
    if (quote) {
      out += c;
      if (c === '\\') {
        out += text[i + 1] ?? '';
        i += 2;
        continue;
      }
      if (c === quote) quote = null;
      i += 1;
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      out += c;
      i += 1;
      continue;
    }
    if (c === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') i += 1;
      continue;
    }
    if (c === '/' && text[i + 1] === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) {
        if (text[i] === '\n') out += '\n';
        i += 1;
      }
      i += 2;
      continue;
    }
    out += c;
    i += 1;
  }
  // 尾逗号：,] 与 ,}
  return out.replace(/,\s*([}\]])/g, '$1');
}

function readJson5(rel) {
  const abs = path.join(appDir, rel);
  if (!existsSync(abs)) {
    fail(`缺少 ${rel}`);
    return null;
  }
  try {
    return JSON.parse(stripJson5(readFileSync(abs, 'utf8')));
  } catch (err) {
    fail(`${rel} 解析失败：${err.message}`);
    return null;
  }
}

// 1. AppScope/app.json5
const appJson = readJson5('AppScope/app.json5');
if (appJson) {
  const bundleName = appJson?.app?.bundleName;
  if (!bundleName) {
    fail('AppScope/app.json5: app.bundleName 缺失');
  } else if (!/^[a-zA-Z][a-zA-Z0-9._-]{2,}$/.test(bundleName)) {
    fail(`AppScope/app.json5: bundleName 非法（${bundleName}）`);
  } else {
    ok(`bundleName = ${bundleName}`);
  }
  const label = appJson?.app?.label;
  if (typeof label === 'string' && label.startsWith('$string:')) {
    const key = label.slice('$string:'.length);
    const strFile = readJson5('AppScope/resources/base/element/string.json');
    if (strFile && !(strFile.string ?? []).some((s) => s.name === key)) {
      fail(`AppScope/resources/base/element/string.json: 缺少 ${key}`);
    } else if (strFile) {
      ok(`label 资源 $string:${key} 存在`);
    }
  }
}

// 2. module.json5
const moduleJson = readJson5('entry/src/main/module.json5');
if (moduleJson) {
  const mod = moduleJson?.module;
  if (!mod?.name) fail('module.json5: module.name 缺失');
  if (!mod?.mainElement) fail('module.json5: mainElement 缺失');
  const pagesProfile = mod?.pages;
  if (typeof pagesProfile === 'string' && pagesProfile.startsWith('$profile:')) {
    const profileName = pagesProfile.slice('$profile:'.length);
    ok(`pages 配置走 $profile:${profileName}`);

    const rel = `entry/src/main/resources/base/profile/${profileName}.json`;
    const pagesJson = readJson5(rel);
    if (pagesJson) {
      const srcs = pagesJson.src ?? [];
      if (srcs.length === 0) fail(`${rel}: src 为空`);
      for (const src of srcs) {
        const ets = path.join(appDir, 'entry/src/main/ets', `${src}.ets`);
        if (!existsSync(ets)) fail(`页面文件不存在：${src}.ets（${rel} 里声明）`);
        else ok(`页面 ${src}.ets 存在`);
      }
    }
  } else {
    fail('module.json5: pages 应指向 $profile:<name>');
  }

  for (const ab of mod?.abilities ?? []) {
    if (typeof ab.srcEntry !== 'string') {
      fail(`ability ${ab.name}: srcEntry 缺失`);
      continue;
    }
    const abs = path.join(appDir, 'entry/src/main', ab.srcEntry.replace(/^\.\//, ''));
    if (!existsSync(abs)) fail(`ability ${ab.name}: srcEntry 不存在（${ab.srcEntry}）`);
    else if (ab.name === mod.mainElement) ok(`mainElement ${ab.name} 的 srcEntry 存在`);
  }
}

// 3. build-profile.json5（JSON 结构合法即可）
const bp = readJson5('build-profile.json5');
if (bp) {
  const mods = bp?.modules ?? [];
  if (!mods.some((m) => m.name === 'entry')) fail('build-profile.json5: modules 里没有 entry');
  else ok('build-profile.json5 modules 含 entry');
}

console.log(`[check-app-json] app=${appDir}`);
for (const m of oks) console.log(`  [ ok ] ${m}`);
for (const m of errors) console.error(`  [fail] ${m}`);
if (errors.length) {
  console.error(`[check-app-json] ${errors.length} 个问题`);
  process.exit(1);
}
console.log(`[check-app-json] OK（结构自检 ${oks.length} 项；未编译，构建仍需 SDK）`);
