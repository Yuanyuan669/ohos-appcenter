import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import { StoreSettings } from '../model/Types';
import { Log } from './Logger';

const NAME = 'appcenter_settings';
const KEY_URL = 'index_url';
const KEY_PIN = 'pin';

/**
 * 设置只有两项：商店地址与可选 PIN。
 * 用 preferences 持久化，冷启动直接恢复。
 */
export class SettingsStore {
  private static store: preferences.Preferences | null = null;

  static async init(context: common.UIAbilityContext): Promise<void> {
    if (SettingsStore.store === null) {
      SettingsStore.store = await preferences.getPreferences(context, NAME);
    }
  }

  static async load(context: common.UIAbilityContext): Promise<StoreSettings> {
    await SettingsStore.init(context);
    const store = SettingsStore.store as preferences.Preferences;
    const url = await store.get(KEY_URL, '') as string;
    const pin = await store.get(KEY_PIN, '') as string;
    return { indexUrl: url, pin: pin };
  }

  /**
   * 先读 preferences；为空则尝试预置文件并回写。
   * 预置文件：<filesDir>/appcenter/index-url.txt
   * 第一行 URL，第二行（可选）PIN。批量部署不用在板上手输地址。
   */
  static async loadEffective(context: common.UIAbilityContext): Promise<StoreSettings> {
    const saved: StoreSettings = await SettingsStore.load(context);
    if (saved.indexUrl.length > 0) {
      return saved;
    }
    const path: string = context.filesDir + '/appcenter/index-url.txt';
    if (!fs.accessSync(path)) {
      return saved;
    }
    let text: string = '';
    try {
      text = fs.readTextSync(path);
    } catch (e) {
      Log.warn('bootstrap url unreadable: ' + JSON.stringify(e));
      return saved;
    }
    const lines: string[] = text.split('\n');
    const url: string = lines.length > 0 ? lines[0].trim() : '';
    const pin: string = lines.length > 1 ? lines[1].trim() : '';
    if (url.length === 0) {
      return saved;
    }
    const boot: StoreSettings = { indexUrl: url, pin: pin };
    try {
      await SettingsStore.save(context, boot);
      Log.info('bootstrap url applied: ' + url);
    } catch (e) {
      Log.warn('bootstrap save failed: ' + JSON.stringify(e));
    }
    return boot;
  }

  static async save(context: common.UIAbilityContext, settings: StoreSettings): Promise<void> {
    await SettingsStore.init(context);
    const store = SettingsStore.store as preferences.Preferences;
    await store.put(KEY_URL, settings.indexUrl);
    await store.put(KEY_PIN, settings.pin);
    await store.flush();
  }
}
