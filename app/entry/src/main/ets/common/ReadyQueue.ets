import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import cryptoFramework from '@ohos.security.cryptoFramework';
import request from '@ohos.request';
import { Log } from '../common/Logger';
import { InstallResult, ReadyRequest } from '../model/Types';

const SUB = 'appcenter';
const HAP_CACHE = 'cache';

/**
 * 设备侧沙箱布局（PC agent 按同一约定轮询）：
 *   <filesDir>/appcenter/
 *     ready/   <requestId>.json + <bundle>-<versionCode>.hap
 *     done/    <requestId>.result.json   （agent 写回）
 *     cache/   下载中转
 */
export class ReadyQueue {
  static baseDir(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/' + SUB;
  }

  static readyDir(ctx: common.UIAbilityContext): string {
    return ReadyQueue.baseDir(ctx) + '/ready';
  }

  static doneDir(ctx: common.UIAbilityContext): string {
    return ReadyQueue.baseDir(ctx) + '/done';
  }

  static cacheDir(ctx: common.UIAbilityContext): string {
    return ReadyQueue.baseDir(ctx) + '/' + HAP_CACHE;
  }

  static ensureDirs(ctx: common.UIAbilityContext): void {
    for (const dir of [ReadyQueue.baseDir(ctx), ReadyQueue.readyDir(ctx),
                       ReadyQueue.doneDir(ctx), ReadyQueue.cacheDir(ctx)]) {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    }
  }

  /** 下载 HAP 到 cache（URL 里已带 PIN），下载完由调用方算 SHA256 */
  static async downloadHap(ctx: common.UIAbilityContext, url: string,
                           fileName: string): Promise<string> {
    ReadyQueue.ensureDirs(ctx);
    const target = ReadyQueue.cacheDir(ctx) + '/' + fileName;
    if (fs.accessSync(target)) {
      fs.unlinkSync(target);
    }
    const task = await request.downloadFile(ctx, {
      url: url,
      filePath: target
    });
    await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      const timer = setTimeout(() => {
        reject(new Error('下载超时（60s）'));
      }, 60000);
      task.on('complete', () => {
        clearTimeout(timer);
        resolve();
      });
      task.on('fail', (code: number) => {
        clearTimeout(timer);
        reject(new Error('下载失败 code=' + code));
      });
    });
    Log.info('downloaded ' + url);
    return target;
  }

  static async sha256(filePath: string): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(64 * 1024);
      for (;;) {
        const readLen = fs.readSync(file.fd, buffer);
        if (readLen <= 0) {
          break;
        }
        const slice = buffer.slice(0, readLen);
        // update() 返回 Promise，必须 await：否则所有分块并发提交，
        // digest 会先于数据落地，算出的哈希是错的（大文件才会暴露）。
        await md.update({ data: new Uint8Array(slice) });
      }
    } finally {
      fs.closeSync(file);
    }
    const digest = await md.digest();
    return hex(digest.data);
  }

  /** 把「已下载且哈希匹配」的 HAP 放进 ready/，等待 PC agent 拉取安装 */
  static enqueue(ctx: common.UIAbilityContext, req: ReadyRequest, cachedPath: string): void {
    ReadyQueue.ensureDirs(ctx);
    const hapName = hapFileName(req.bundleName, req.versionCode);
    const dest = ReadyQueue.readyDir(ctx) + '/' + hapName;
    fs.copyFileSync(cachedPath, dest);
    ReadyQueue.writeJson(ReadyQueue.readyDir(ctx) + '/' + req.id + '.json', req);
  }

  static async pollResult(ctx: common.UIAbilityContext, requestId: string): Promise<InstallResult | null> {
    const path = ReadyQueue.doneDir(ctx) + '/' + requestId + '.result.json';
    if (!fs.accessSync(path)) {
      return null;
    }
    const text = fs.readTextSync(path);
    return JSON.parse(text) as InstallResult;
  }

  static writeJson(path: string, obj: Object): void {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(obj));
    } finally {
      fs.closeSync(file);
    }
  }
}

export function hapFileName(bundleName: string, versionCode: number): string {
  return bundleName + '-' + versionCode + '.hap';
}

function hex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    const v = bytes[i];
    out += v < 16 ? '0' + v.toString(16) : v.toString(16);
  }
  return out;
}
