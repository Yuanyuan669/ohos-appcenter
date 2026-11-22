import http from '@ohos.net.http';
import { Log } from '../common/Logger';
import { StoreIndex, StoreSettings } from '../model/Types';

/**
 * 拉取 store/index.json。设备只需要 GET，不需要任何写入权限。
 * 网络失败 / 非 200 / PIN 错误都抛 StoreError，由页面显示原文（不吞错）。
 *
 * PIN 走 query 参数（?pin=...）而不是请求头：设备端 `request.downloadFile`
 * 与 `http.request` 的两套 header 类型不一致，query 更省事；服务端两种都认。
 */
export class StoreError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'StoreError';
  }
}

export class StoreClient {
  static async fetchIndex(settings: StoreSettings): Promise<StoreIndex> {
    const url = StoreClient.withPin(settings.indexUrl, settings.pin);
    if (!url || url.length < 8) {
      throw new StoreError('未配置商店地址：请在设置里填写 http://<PC-IP>:8787/index.json');
    }
    const client = http.createHttp();
    try {
      const resp = await client.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 15000
      });
      if (resp.responseCode === 401) {
        throw new StoreError('PIN 无效（HTTP 401）');
      }
      if (resp.responseCode !== 200) {
        throw new StoreError('商店返回 HTTP ' + resp.responseCode);
      }
      const text = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      const index = JSON.parse(text) as StoreIndex;
      if (!index || index.schemaVersion !== 1 || !Array.isArray(index.apps)) {
        throw new StoreError('索引格式不符（schemaVersion != 1）');
      }
      return index;
    } finally {
      client.destroy();
    }
  }

  /** HAP 真实下载地址：优先 baseUrl，其次 indexUrl 同目录；PIN 一并带上 */
  static resolveHapUrl(settings: StoreSettings, index: StoreIndex, hapRel: string): string {
    let base = '';
    if (index.baseUrl && index.baseUrl.length > 0) {
      base = index.baseUrl;
    } else {
      base = settings.indexUrl.replace(/\/[^\/]*$/, '');
    }
    return StoreClient.withPin(trimSlash(base) + '/' + hapRel, settings.pin);
  }

  static withPin(url: string, pin: string): string {
    if (!pin) {
      return url;
    }
    const sep = url.indexOf('?') >= 0 ? '&' : '?';
    return url + sep + 'pin=' + encodeURIComponent(pin);
  }

  static logInfo(msg: string): void {
    Log.info(msg);
  }
}

function trimSlash(s: string): string {
  let out = s;
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}
