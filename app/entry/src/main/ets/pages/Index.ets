import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { AppEntry, ReadyRequest, StoreIndex, StoreSettings } from '../model/Types';
import { SettingsStore } from '../common/SettingsStore';
import { StoreClient, StoreError } from '../common/StoreClient';
import { ReadyQueue, hapFileName } from '../common/ReadyQueue';

interface CardState {
  bundleName: string;
  phase: string; // idle | downloading | ready | installed | failed
  detail: string;
}

/**
 * 首页：商店列表 + 下载 + 入队。
 *
 * 边界（务必在 UI 里说清楚）：普通应用无法安装任意 HAP，下载完成后只能把
 * HAP 放进沙箱 ready/，由 PC 侧 `agent/pc-agent.mjs` 执行 hdc install。
 */
@Entry
@Component
struct Index {
  @State apps: AppEntry[] = [];
  @State loading: boolean = false;
  @State errorText: string = '';
  @State states: CardState[] = [];
  @State settings: StoreSettings = { indexUrl: '', pin: '' };
  private index: StoreIndex | null = null;
  private ctx: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    this.reload();
  }

  async reload(): Promise<void> {
    const ctx = this.ctx;
    if (ctx === null) {
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      this.settings = await SettingsStore.loadEffective(ctx);
      const index: StoreIndex = await StoreClient.fetchIndex(this.settings);
      this.index = index;
      this.apps = index.apps;
      this.states = index.apps.map((a: AppEntry) => {
        const s: CardState = { bundleName: a.bundleName, phase: 'idle', detail: '' };
        return s;
      });
      StoreClient.logInfo('index loaded: ' + index.apps.length);
    } catch (e) {
      const err = e as Error;
      this.errorText = err instanceof StoreError ? err.message : ('加载失败：' + err.message);
      this.apps = [];
    } finally {
      this.loading = false;
    }
  }

  stateOf(bundleName: string): CardState {
    for (const s of this.states) {
      if (s.bundleName === bundleName) {
        return s;
      }
    }
    return { bundleName: bundleName, phase: 'idle', detail: '' };
  }

  updateState(bundleName: string, phase: string, detail: string): void {
    const next = this.states.map((s: CardState) => {
      if (s.bundleName !== bundleName) {
        return s;
      }
      const changed: CardState = { bundleName: s.bundleName, phase: phase, detail: detail };
      return changed;
    });
    this.states = next;
  }

  async install(app: AppEntry): Promise<void> {
    const latest = app.latest;
    const index = this.index;
    const ctx = this.ctx;
    if (index === null || ctx === null) {
      this.updateState(app.bundleName, 'failed', '索引未加载，请先刷新');
      return;
    }
    this.updateState(app.bundleName, 'downloading', '下载中…');
    try {
      const url = StoreClient.resolveHapUrl(this.settings, index, latest.hap);
      const cacheName = hapFileName(app.bundleName, latest.versionCode);
      const local = await ReadyQueue.downloadHap(ctx, url, cacheName);
      const actual = await ReadyQueue.sha256(local);
      if (actual.toLowerCase() !== latest.sha256.toLowerCase()) {
        this.updateState(app.bundleName, 'failed', 'SHA256 不符，已丢弃');
        return;
      }
      const requestId = requestIdFor(app.bundleName, latest.versionCode);
      const req: ReadyRequest = {
        id: requestId,
        bundleName: app.bundleName,
        versionCode: latest.versionCode,
        versionName: latest.versionName,
        hap: cacheName,
        sizeBytes: latest.sizeBytes,
        sha256: latest.sha256,
        requestedAt: new Date().toISOString()
      };
      ReadyQueue.enqueue(ctx, req, local);
      this.updateState(app.bundleName, 'ready', '已就绪，等待电脑侧 agent 安装');
      promptAction.showToast({ message: '已下载，电脑上运行 agent 即会安装' });
    } catch (e) {
      const err = e as Error;
      this.updateState(app.bundleName, 'failed', err.message);
    }
  }

  @Builder
  headerCard() {
    Row() {
      Column() {
        Text('应用中心').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#F3F7FF')
        Text(this.settings.indexUrl ? this.settings.indexUrl : '未配置商店地址')
          .fontSize(12).fontColor('#8B9AB3').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button('设置')
        .fontSize(14).height(34)
        .backgroundColor('#1B2536').fontColor('#CFE0F5')
        .onClick(() => { router.pushUrl({ url: 'pages/Settings' }); })
      Blank().width(8)
      Button(this.loading ? '刷新中' : '刷新')
        .fontSize(14).height(34).enabled(!this.loading)
        .backgroundColor('#1B2536').fontColor('#CFE0F5')
        .onClick(() => { this.reload(); })
    }
    .width('100%').padding(16)
    .backgroundColor('#141B27').borderRadius(14)
  }

  @Builder
  appCard(app: AppEntry) {
    Column() {
      Row() {
        Column() {
          Text(app.name).fontSize(18).fontWeight(FontWeight.Medium).fontColor('#F3F7FF')
          Text(app.summary).fontSize(12).fontColor('#8B9AB3').maxLines(2)
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(app.category).fontSize(11).fontColor('#4FC3F7')
      }
      .width('100%')

      Blank().height(10)
      Row() {
        Text(app.bundleName + ' · v' + app.latest.versionName + ' · ' + sizeText(app.latest.sizeBytes))
          .fontSize(11).fontColor('#8B9AB3').layoutWeight(1)
        Button(phaseText(this.stateOf(app.bundleName).phase))
          .fontSize(13).height(30)
          .backgroundColor(this.stateOf(app.bundleName).phase === 'installed' ? '#214D3B' : '#21455C')
          .fontColor('#EAF4FF')
          .enabled(this.stateOf(app.bundleName).phase === 'idle' || this.stateOf(app.bundleName).phase === 'failed')
          .onClick(() => { this.install(app); })
      }
      .width('100%')

      if (this.stateOf(app.bundleName).detail) {
        Text(this.stateOf(app.bundleName).detail)
          .fontSize(11).fontColor('#F2B45C').margin({ top: 6 })
      }
    }
    .width('100%').padding(16).margin({ bottom: 10 })
    .backgroundColor('#141B27').borderRadius(14)
  }

  build() {
    Column() {
      this.headerCard()
      Blank().height(10)

      if (this.errorText) {
        Text(this.errorText).fontSize(13).fontColor('#FF7B7B').padding(12)
      }

      if (this.apps.length === 0 && !this.loading && !this.errorText) {
        Text('商店里还没有应用：把已签名的 HAP 放进 PC 侧 store/apps/ 后重新 build-index。')
          .fontSize(13).fontColor('#8B9AB3').padding(12)
      }

      Scroll() {
        Column() {
          ForEach(this.apps, (app: AppEntry) => {
            this.appCard(app)
          }, (app: AppEntry) => app.bundleName)
        }.padding({ left: 4, right: 4 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%').height('100%')
    .padding(16)
    .backgroundColor('#0B0F17')
  }
}

function sizeText(bytes: number): string {
  const mb = bytes / (1024 * 1024);
  return mb >= 1 ? mb.toFixed(1) + ' MB' : (bytes / 1024).toFixed(0) + ' KB';
}

function phaseText(phase: string): string {
  if (phase === 'downloading') {
    return '下载中';
  }
  if (phase === 'ready') {
    return '待安装';
  }
  if (phase === 'installed') {
    return '已安装';
  }
  if (phase === 'failed') {
    return '重试';
  }
  return '下载';
}

function nowId(): string {
  return String(Date.now());
}

/**
 * ready 请求 ID。agent 侧校验规则是 ^[a-zA-Z0-9_-]{8,64}$（不含点），
 * 所以把 bundleName 里的点和其它非法字符换成 '-'，例如
 *   com.local.homekiosk + 1000000 -> com-local-homekiosk-1000000-1795361236627
 */
function requestIdFor(bundleName: string, versionCode: number): string {
  let safe = '';
  for (let i = 0; i < bundleName.length; i++) {
    const c = bundleName.charAt(i);
    const ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9') || c === '_' || c === '-';
    safe += ok ? c : '-';
  }
  return safe + '-' + versionCode + '-' + nowId();
}
