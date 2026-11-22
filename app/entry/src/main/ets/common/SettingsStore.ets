import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import { StoreSettings } from '../model/Types';

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

  static async save(context: common.UIAbilityContext, settings: StoreSettings): Promise<void> {
    await SettingsStore.init(context);
    const store = SettingsStore.store as preferences.Preferences;
    await store.put(KEY_URL, settings.indexUrl);
    await store.put(KEY_PIN, settings.pin);
    await store.flush();
  }
}
