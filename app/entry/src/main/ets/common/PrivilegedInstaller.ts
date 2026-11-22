/* eslint-disable @typescript-eslint/no-explicit-any */
// 静默安装的 systemapi 模块不在公开 SDK 的 d.ts 里，tsc 会报找不到模块；
// 设备上它注册为 NAPI 模块 "bundle.installer"（/system/lib64/module/bundle/libinstaller.z.so）。
// @ts-ignore
import installerModule from '@ohos.bundle.installer';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';

/** 一次静默安装尝试的结果。code 沿用 OpenHarmony 错误码，201 = 没有 INSTALL_BUNDLE 权限。 */
export interface InstallAttempt {
  ok: boolean;
  code: number;
  message: string;
}

export const ERR_NO_PERMISSION = 201;
/** 已装版本与本包签名不一致：只能卸载后重装（会清空该应用数据）。 */
const ERR_SIGNATURE_INCONSISTENT = 17700011;

const DOMAIN = 0x0001;
const USER_ID = 100;
/**
 * installFlag 取值来自 4.1 的 InstallFlag 枚举（installer.cpp 只接受这三个）：
 *   NORMAL = 0、REPLACE_EXISTING = 1、FREE_INSTALL = 0x10
 * REPLACE_EXISTING 的语义是「新版本不低于旧版本即可覆盖」，同版本重装靠它；
 * 传 2/3 属于非法值，会被当成 NORMAL，然后报 17700047。
 */
const INSTALL_FLAG_REPLACE_EXISTING = 1;

/**
 * 特权安装：商店以 system_core 身份签名后，可以直接调用系统安装器，
 * 不再需要 PC 侧 agent。
 *
 * 为什么是 .ts 而不是 .ets：`@ohos.bundle.installer` 是 systemapi 模块，
 * 公开 SDK 里没有它的 d.ts，ArkTS 的 .ets 校验会拒绝；.ts 里用 ts-ignore
 * 跳过类型解析即可，运行时仍按 `requireNapi('bundle.installer')` 加载。
 *
 * 包如果按 normal 身份签名，这里会抛 201，调用方据此回退到 ready/ + PC agent。
 */
export class PrivilegedInstaller {
  /** 探针：只验证权限是否到位，不装任何东西。返回 0 表示可用。 */
  static async available(): Promise<number> {
    try {
      const inst = await installerModule.getBundleInstaller();
      return inst === undefined || inst === null ? -1 : 0;
    } catch (e) {
      return errorCode(e);
    }
  }

  /**
   * 安装，必要时覆盖/重装：
   *   1) 直接装（新装）
   *   2) 带 REPLACE_EXISTING 再装（同版本重装/升级，允许 versionCode 不低于旧版）
   *   3) 仍报签名不一致 -> 先卸载旧包再装（跨证书迁移，清空目标应用数据）
   */
  static async install(hapPath: string, bundleName: string): Promise<InstallAttempt> {
    const fresh = await PrivilegedInstaller.attempt(hapPath, { userId: USER_ID });
    if (fresh.ok) {
      return fresh;
    }
    const replaced = await PrivilegedInstaller.attempt(hapPath,
      { userId: USER_ID, installFlag: INSTALL_FLAG_REPLACE_EXISTING });
    if (replaced.ok) {
      return replaced;
    }
    if (replaced.code !== ERR_SIGNATURE_INCONSISTENT) {
      return replaced;
    }
    hilog.warn(DOMAIN, 'AppCenter',
      'signature mismatch for %{public}s, uninstall then reinstall', bundleName);
    const removed = await PrivilegedInstaller.uninstall(bundleName);
    if (!removed.ok) {
      return removed;
    }
    const reinstalled = await PrivilegedInstaller.attempt(hapPath, { userId: USER_ID });
    if (reinstalled.ok) {
      return { ok: true, code: 0, message: 'reinstalled' };
    }
    return reinstalled;
  }

  private static async uninstall(bundleName: string): Promise<InstallAttempt> {
    try {
      const inst = await installerModule.getBundleInstaller();
      await inst.uninstall(bundleName, { userId: USER_ID });
      hilog.info(DOMAIN, 'AppCenter', 'privileged uninstall ok: %{public}s', bundleName);
      return { ok: true, code: 0, message: '' };
    } catch (e) {
      const code = errorCode(e);
      const message = errorMessage(e);
      hilog.warn(DOMAIN, 'AppCenter', 'privileged uninstall failed code=%{public}d %{public}s', code, message);
      return { ok: false, code: code, message: message };
    }
  }

  private static async attempt(hapPath: string, param: any): Promise<InstallAttempt> {
    try {
      const inst = await installerModule.getBundleInstaller();
      await inst.install([hapPath], param);
      hilog.info(DOMAIN, 'AppCenter', 'privileged install ok: %{public}s', hapPath);
      return { ok: true, code: 0, message: '' };
    } catch (e) {
      const code = errorCode(e);
      const message = errorMessage(e);
      hilog.warn(DOMAIN, 'AppCenter', 'privileged install failed code=%{public}d flag=%{public}d %{public}s',
        code, param['installFlag'] === undefined ? 0 : param['installFlag'], message);
      return { ok: false, code: code, message: message };
    }
  }
}

function errorCode(e: any): number {
  const be = e as BusinessError;
  return be.code === undefined ? -1 : be.code;
}

function errorMessage(e: any): string {
  const be = e as BusinessError;
  return be.message === undefined ? String(e) : be.message;
}
