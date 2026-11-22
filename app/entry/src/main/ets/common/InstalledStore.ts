/* eslint-disable @typescript-eslint/no-explicit-any */
// 查询设备上其它应用的安装信息。
//
// 4.1 里能查别的包的接口是 `bundleManager.getBundleInfo(bundleName, flags, userId)`，
// 它属于 systemapi：公开 SDK 的 d.ts 只留了 getBundleInfoForSelf，所以这里用 .ts
// + ts-ignore 调用，运行时由 libbundlemanager.z.so 提供。
//
// 需要 ohos.permission.GET_BUNDLE_INFO_PRIVILEGED（system_core + ACL，见
// scripts/env.sh 的 OHOS_ALLOWED_ACLS）。没有这个权限时查不到，卡片只是退化为
// 「下载」状态，不影响安装链路。
//
// 另留一条旧接口兜底：@ohos.bundle.getBundleInfo 在公开 d.ts 里仍在（标记
// deprecated since 9），部分版本上比 bundleManager 的新接口更容易拿到。
// @ts-ignore
import bundleManager from '@ohos.bundle.bundleManager';
// @ts-ignore
import legacyBundle from '@ohos.bundle';
import hilog from '@ohos.hilog';

export interface InstalledVersion {
  versionCode: number;
  versionName: string;
}

const DOMAIN = 0x0001;
const USER_ID = 100;

export class InstalledStore {
  /** 返回已安装版本；未安装或无权查询时返回 null（调用方按「未安装」显示）。 */
  static async get(bundleName: string): Promise<InstalledVersion | null> {
    try {
      // @ts-ignore getBundleInfo 不在公开 d.ts 中（systemapi）
      const info = await bundleManager.getBundleInfo(bundleName, 0, USER_ID);
      const version = toVersion(info);
      if (version !== null) {
        return version;
      }
    } catch (e) {
      // 落到旧接口
    }
    try {
      // @ts-ignore @ohos.bundle.getBundleInfo 自 API 9 起标记 deprecated
      const info = await legacyBundle.getBundleInfo(bundleName, 0, { userId: USER_ID });
      return toVersion(info);
    } catch (e) {
      const err = e as any;
      const message = err.code === undefined ? String(e) : (err.code + ' ' + err.message);
      hilog.debug(DOMAIN, 'AppCenter', 'query %{public}s failed: %{public}s', bundleName, message);
      return null;
    }
  }
}

function toVersion(info: any): InstalledVersion | null {
  if (info === undefined || info === null) {
    return null;
  }
  const code = info.versionCode as number;
  const name = info.versionName as string;
  if (typeof code !== 'number' || code <= 0) {
    return null;
  }
  return { versionCode: code, versionName: name === undefined || name === null ? '' : name };
}
