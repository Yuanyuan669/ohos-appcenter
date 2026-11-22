import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { StoreSettings } from '../model/Types';
import { SettingsStore } from '../common/SettingsStore';
import { ReadyQueue } from '../common/ReadyQueue';
import { Log } from '../common/Logger';

/**
 * 设置页：商店地址 + 可选 PIN。
 *
 * 商店地址就是 PC 侧 `node tools/serve.mjs` 打印的 URL，例如
 *   http://192.168.31.27:8787/index.json
 * 同网段才能直连；设备访问不了外网时这是唯一可用路径。
 */
@Entry
@Component
struct SettingsPage {
  @State indexUrl: string = '';
  @State pin: string = '';
  @State saving: boolean = false;
  @State sandboxPath: string = '';
  private ctx: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    this.sandboxPath = ReadyQueue.baseDir(this.ctx);
    SettingsStore.loadEffective(this.ctx).then((s: StoreSettings) => {
      this.indexUrl = s.indexUrl;
      this.pin = s.pin;
    }).catch((e: Error) => {
      Log.warn('load settings failed: ' + e.message);
    });
  }

  private async save(): Promise<void> {
    const ctx = this.ctx;
    if (ctx === null) {
      return;
    }
    this.saving = true;
    try {
      const url = this.indexUrl.trim();
      const settings: StoreSettings = { indexUrl: url, pin: this.pin.trim() };
      await SettingsStore.save(ctx, settings);
      promptAction.showToast({ message: '已保存' });
      router.back();
    } catch (e) {
      const err = e as Error;
      promptAction.showToast({ message: '保存失败：' + err.message });
    } finally {
      this.saving = false;
    }
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(14).height(34)
          .backgroundColor('#1B2536').fontColor('#CFE0F5')
          .onClick(() => { router.back(); })
        Blank().width(10)
        Text('设置').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#F3F7FF').layoutWeight(1)
      }
      .width('100%').padding({ bottom: 12 })

      Column() {
        Text('商店地址').fontSize(13).fontColor('#8B9AB3')
        TextInput({ text: this.indexUrl, placeholder: 'http://192.168.31.27:8787/index.json' })
          .fontSize(14).height(44).margin({ top: 6 })
          .backgroundColor('#0F1622').fontColor('#F3F7FF')
          .onChange((value: string) => { this.indexUrl = value; })
        Text('PC 侧运行 node tools/serve.mjs 后会打印这个地址；必须是同网段可访问的 http(s)。')
          .fontSize(11).fontColor('#8B9AB3').margin({ top: 6 })

        Blank().height(16)
        Text('PIN（可选）').fontSize(13).fontColor('#8B9AB3')
        TextInput({ text: this.pin, placeholder: 'serve.mjs 带 --pin 时才需要' })
          .fontSize(14).height(44).margin({ top: 6 })
          .backgroundColor('#0F1622').fontColor('#F3F7FF')
          .onChange((value: string) => { this.pin = value; })
        Text('serve.mjs 启动时带的 PIN；留空表示不校验。')
          .fontSize(11).fontColor('#8B9AB3').margin({ top: 6 })
      }
      .width('100%').padding(16).backgroundColor('#141B27').borderRadius(14)

      Blank().height(12)
      Column() {
        Text('设备侧交接目录').fontSize(13).fontColor('#8B9AB3')
        Text(this.sandboxPath)
          .fontSize(12).fontColor('#4FC3F7').margin({ top: 6 })
          .copyOption(CopyOptions.LocalDevice)
        Text('PC agent 需要 -sandbox 指向这个目录：下载的 HAP 与 ready/*.json 放在这里，等电脑侧 hdc install。')
          .fontSize(11).fontColor('#8B9AB3').margin({ top: 6 })
      }
      .width('100%').padding(16).backgroundColor('#141B27').borderRadius(14)

      Blank().height(20)
      Button(this.saving ? '保存中…' : '保存')
        .width('100%').height(44).enabled(!this.saving)
        .backgroundColor('#4FC3F7').fontColor('#06121C')
        .onClick(() => { this.save(); })

      Blank().layoutWeight(1)
    }
    .width('100%').height('100%')
    .padding(16)
    .backgroundColor('#0B0F17')
  }
}
