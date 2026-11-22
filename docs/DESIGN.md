# 设计说明

## 1. 目标与边界

在 LHT16（OpenHarmony 4.1.7.5 / API 11）开发板上替代已失联的厂商分发中心
`com.laval.dispatchcenter`（后端 `dispatchcenter.laval.aidog.club` DNS 已失效、页面空白）。
旧中心之所以能「点一下自动装」，是因为它是 `system_core` 应用并持有
`ohos.permission.INSTALL_BUNDLE`，而不是因为它有某种特殊接口。

本仓做一个**可复制、可审计、可离线**的分发闭环：

1. **索引**：`store/apps/` 收 HAP，生成并校验 `store/index.json`（`docs/INDEX-SPEC.md`）。
2. **设备端商店**：`com.local.appcenter` 浏览、下载、SHA256 校验，然后**在本机静默安装**。
3. **PC agent（兜底）**：当商店按 `normal` 身份构建、或安装接口返回 `201` 时，
   `hdc file recv` 拉回、再校验、`hdc install -r` 安装、写回结果。

边界与取舍：

- **不预置进系统分区**。商店用 OpenHarmony 测试 PKI 签成 `apl=system_core` +
  `hos_system_app` + ACL `INSTALL_BUNDLE`，`bm install` 直接接受，落在 `/data/app`。
  没有 remount、没有 OTA 校验和风险；装错就卸载重装。
- 签名能力来自 Profile 字段与证书链，不是「改了系统」。普通应用拿不到这个权限，
  所以 `normal` 变体仍然只走 agent（见 §4）。
- 索引信任 = 「索引声明的 SHA256 + 发布前本地验签」（`tools/verify-store-haps.sh`）。
  不自动信任任意第三方签名。
- 不做在线支付、账号、推荐算法、灰度发布。

## 2. 为什么商店要做成系统应用

```
┌────────────┐   GET index.json / *.hap    ┌──────────────┐
│ 开发板      │ ──────────────────────────▶ │ PC: serve.mjs │
│ appcenter  │                             │  store/       │
│system_core │ ◀────────────────────────── │  index.json   │
└─────┬──────┘        下载 + SHA256 校验      └──────────────┘
      │ 校验通过
      ▼
┌────────────────────────────────────────────┐
│ @ohos.bundle.installer（NAPI bundle.installer）│
│ install([hap], { userId: 100 })            │
│ 失败 → installFlag=1 → 17700011 才卸载重装    │
└────────────────────────────────────────────┘
```

这条链的关键取舍：

- **体验正确**：用户点「下载」后几秒内看到「已安装」，中间不需要电脑。
- **权限正确**：安装动作由系统安装器执行，商店只发起请求；`INSTALL_BUNDLE`
  是通过 Profile 的 `apl/app-feature/ACL` 合法获得的，不是绕过权限。
- **风险可控**：`system_core` 包照样装载 `/data/app`，卸载即恢复；不需要改系统分区。
- **可退**：`OHOS_APL=normal` 重签即回到 §2.1 的 PC 兜底链，功能降级但不报错。

### 2.1 兜底链（normal 变体 / 201）

```
┌────────────┐   GET index.json / *.hap    ┌──────────────┐
│ 开发板      │ ──────────────────────────▶ │ PC: serve.mjs │
│ appcenter  │                             │  store/       │
│ (普通应用)  │ ◀────────────────────────── │  index.json   │
└─────┬──────┘        下载 + SHA256 校验      └──────────────┘
      │ 写入沙箱
      │ <filesDir>/appcenter/ready/{x.json, x.hap}
      ▼
┌────────────────────────────────────────────────────────────┐
│ hdc（USB 或 tcp 5555）                                      │
└────────────────────────────┬───────────────────────────────┘
                             ▼
                ┌──────────────────────────┐
                │ PC: agent/pc-agent.mjs   │
                │  recv → 复核 SHA256      │
                │  → hdc install -r        │
                │  → done/{x.result.json}  │
                └──────────────────────────┘
```

兜底链的代价是**需要一台 PC 常连**；它的价值在于：设备侧只读网络、不需要任何
系统权限，安装动作留在 PC 日志里，适合不想给商店系统身份的场景。

## 3. 时序（一次安装）

1. 设备：商店地址来自 `Settings.ets`，或预置文件。
   `SettingsStore.loadEffective` 先读 preferences；为空则读
   `<filesDir>/appcenter/index-url.txt`（第一行 URL、第二行可选 PIN），读到后回写 preferences。
   批量部署不必在板上手输地址。
2. 设备：首页 `GET indexUrl?pin=…`（可选 PIN）。
   - 非 200 / 401 / `schemaVersion != 1` → 页面显示原文，不清空已有列表。
   - 列表渲染后 `InstalledStore` 在后台逐项查 `getBundleInfo(bundleName, 0, 100)`：
     已装且版本不低 → 卡片「已安装 vX」；已装但更低 → 「更新」；未装（错误码 `1`）
     或没权限 → 保持「下载」。查询不阻塞渲染，也不影响安装。
3. 用户点「下载」：
   - `StoreClient.resolveHapUrl` 用 `index.baseUrl`，为空则取 `indexUrl` 同目录。
   - `@ohos.request.downloadFile` 下载到 `<filesDir>/appcenter/cache/<bundle>-<versionCode>.hap`，
     等到 `complete` 事件（带 60 s 超时）。
   - `cryptoFramework` 分块 SHA256（每块 `await md.update()`），与 `latest.sha256`
     比对；不符即丢弃并提示。**注意**：索引更新后设备必须刷新/重启，否则内存里还是
     旧哈希，会误报「SHA256 不符」。
4. 设备：`PrivilegedInstaller.install(hapPath, bundleName)`：
   1. `install([hap], { userId: 100 })`；
   2. 失败带 `installFlag: 1`（4.1 的 `REPLACE_EXISTING`）重试。**注意** 4.1 的
      `InstallFlag` 只有 `NORMAL=0` / `REPLACE_EXISTING=1` / `FREE_INSTALL=0x10`；
      传 `2` 会被当成非法值、退化为 `NORMAL`，同版本重装就报 `17700047`；
   3. 仍报 `17700011`（签名与已装版本不一致）→ `uninstall(bundleName, { userId: 100 })`
      后再装一次；
   4. 成功 → 卡片「已安装 vX.Y.Z」；`201` → 回退到第 5 步。
5. （仅兜底）设备：`ReadyQueue.enqueue` 复制到 `ready/`，写 `ready/<requestId>.json`：
   ```json
   { "id": "...", "bundleName": "...", "versionCode": 1000000, "versionName": "1.0.0",
     "hap": "com.local.homekiosk-1000000.hap", "sizeBytes": 1234567,
     "sha256": "…", "requestedAt": "2026-…Z" }
   ```
   `requestId` 必须匹配 agent 的 `^[a-zA-Z0-9_-]{8,64}$`（**不含点**），所以设备端用
   `requestIdFor()` 把 bundleName 里的 `.` 等非法字符换成 `-`：
   `com.local.homekiosk` + `1000000` → `com-local-homekiosk-1000000-<epochMs>`。
6. （仅兜底）PC：`pc-agent.mjs` 轮询 `ls ready/`：
   - `cat` 元数据 → 校验字段（`agent/lib/agent-lib.mjs::parseReadyMeta`）。
   - `hdc file recv` 拉回本地临时目录，重新算 SHA256（不信任设备侧结果）。
   - 不符 → 写 `done/<id>.result.json`，`status=failed`，不动设备。
   - 相符 → `hdc install -r`；成功则写 `status=installed` 并把 ready 文件移入 `done/`。
   - `9568332 sign info inconsistent`（设备上已有签名不同的同包名版本）→ 先
     `hdc uninstall` 再装一次，仍失败才写 `failed`。

`--dry-run` 会打印将执行的动作但不 recv/install，用于先核对路径与元数据。


## 4. 沙箱路径与 agent 参数

设备侧根目录是 `ctx.filesDir + '/appcenter'`。默认（`system_core`）安装不需要
agent；这些路径只有兜底链会用到。设置页会直接显示根目录（可复制）。
PC 侧对应参数：

```
node agent/pc-agent.mjs --once --serial <serial> \
  --sandbox /data/app/el2/100/base/com.local.appcenter/haps/entry/files/appcenter
```

注意这是 **EL2 / 用户 100** 的沙箱路径；设备上以 `bm dump -n com.local.appcenter` 或设置页
显示的值为准。agent 默认值按同一约定写死，换包名/多用户时要显式传 `--sandbox`。

预置地址文件就在同一层：`<sandbox>/../index-url.txt`，即
`…/haps/entry/files/appcenter/index-url.txt`。仓库里的 `tools/dev-set-prefs.sh`
会写这个文件、从 `files/` 属主动态取沙箱 uid 再 `chown`、重启应用并截图：

```bash
bash tools/dev-set-prefs.sh http://192.168.31.100:8787/index.json
```

> 沙箱 uid 由系统在安装时分配，**重装会变**。脚本不硬编码 uid，而是读 `files/`
> 的属主；否则 root 推上去的文件会让应用 `Permission denied`。

### 4.1 构建、签名、部署（无 IDE）

`scripts/` 与 `ohos-kiosk` 同源，可直接用于本仓：

```bash
bash scripts/doctor.sh                # 17 项环境自检
bash scripts/make-signing-material.sh # signing/*.p12|cer|p7b（一次性/换机重跑）
bash scripts/build.sh                 # hvigor assembleHap -> entry-unsigned.hap
bash scripts/sign.sh                  # hap-sign-tool localSign + verify-app
OHOS_TARGET=<serial> bash scripts/deploy.sh
```

- 签名用 SDK 自带 `OpenHarmony.p12` 里的 **测试 PKI 根/中间 CA 私钥**，给
  `com.local.appcenter` 签一张 10 年证书，stock 镜像直接信任；不需要厂商证书。
- Profile 的 `apl` / `app-feature` / `allowed-acls` 由 `scripts/env.sh` 的
  `OHOS_APL` / `OHOS_APP_FEATURE` / `OHOS_ALLOWED_ACLS` 决定，默认
  `system_core` / `hos_system_app` / `INSTALL_BUNDLE`。细节见 `docs/SIGNING.md`。
- hvigor 3.2.4 靠 `NODE_PATH=$OHOS_TOOLS/hvigor-3.2.4/node_modules` 找到
  `@ohos/hvigor-ohos-plugin`；`env.sh` 已设置。
- API 切换：`$OHOS_BASE_SDK_HOME/openharmony` 是指向 4.0/4.1 的 junction，
  `10`/`11` 是版本号目录。改 API 时同步改 `app/build-profile.json5` 的
  `compileSdkVersion`/`compatibleSdkVersion`，再重跑 `build.sh`。

## 5. 安全

已做：

- 传输：SHA256 端到端校验（设备校验一次，兜底链 PC 再校验一次），任何一环不符都不安装。
- 路径：`isSafeRelative` 拒绝绝对路径/`..`/反斜杠/NUL；agent 侧 `parseReadyMeta` 只接受
  合法 `bundleName`、正整数 `versionCode`、64 位小写 SHA256、`.hap` 文件名（取 basename，
  不接受路径穿越）。
- 服务：`serve.mjs` 只允许 GET/HEAD，路径拼接前先拒绝 `..`，可选 PIN 门。
- 权限：商店申请 `INTERNET` + `INSTALL_BUNDLE` + `GET_BUNDLE_INFO_PRIVILEGED`。后两者是
  `system_core` Profile 显式授予的 ACL：安装权限只用于装「索引里声明了 SHA256 且设备侧
  校验通过」的 HAP；查询权限只读 `versionCode`/`versionName`，用来在卡片上显示
  「已安装 / 更新」。不申请读写他人沙箱。
- 发布：`tools/verify-store-haps.sh` 在入索引前逐个验签并比对 Profile 包名，
  防止「签名链有效但包名错」的包进店（它会导致设备端 `17700011`）。

未做（明确欠账）：

- **签名固定（pinning）**。设备端只比对索引给的 SHA256，没有固定 issuer/fingerprint；
  索引若被篡改，等于信任被篡改。缓解手段是 LAN 内自建、PIN + 人工核对哈希；正式方案应
  校验 OpenHarmony 应用签名并固定 `issuer`/证书指纹（附录 B 的 `signature` 字段留了位置）。
- **索引签名**。`index.json` 没有签名，靠 HTTPS 或内网可信。
- **回滚保护**。允许同 `versionCode` 覆盖安装，未做防降级。
- **PIN 强度**。PIN 走明文 HTTP query/header，只防误连，不防抓包。

## 6. 已知环境限制（诚实记录）

- 2026-11-22 已在本机补齐工具链并**真机验证**：OpenHarmony 4.0 / 4.1 SDK、
  hdc 1.3.0a、hvigor 3.2.4、OpenJDK 17、hap-sign-tool；
  `scripts/{build,sign,deploy}.sh` 全链路跑通，商店首页在 LHT16 上正常渲染。
- 2026-11-23 验证 `apl=system_core` 路线：测试 PKI 能签出 `system_core`，
  `bm install` 直接接受，`bm dump` 显示 `isSystemApp=true`、`INSTALL_BUNDLE` granted，
  且 codePath 在 `/data/app`（不需要动系统分区）。
- 公开 SDK 的 `ets/api` 裁掉了 `@ohos.bundle.installer` 的 `d.ts`，只能按 NAPI 模块
  `bundle.installer` 动态加载（`.ts` + `@ts-ignore`）。同理 `bundleManager.getBundleInfo`
  （查别的包）只留了 `getBundleInfoForSelf`，也要 `.ts` + ts-ignore；查不到的包返回错误码
  `1`，按「未安装」处理即可。
- **包名错误是真实的坑**：各仓 `scripts/env.sh` 的默认 `OHOS_BUNDLE` 曾出现串写
  （`ohos-browser` 写成 `com.local.transfer`，`OhMyBili` 写成 `com.local.homeime`），
  签出来的 HAP 内嵌 Profile 包名对不上，设备一律报 `17700011`。所以发布前必须跑
  `tools/verify-store-haps.sh`。
- 设备网络：`*.workers.dev`、`raw.githubusercontent.com` 不可达；GitHub Release 下载常失败。
  所以默认方案是 LAN 内 `node tools/serve.mjs`，不依赖公网。
- 上传到设备的路径依赖多用户/EL2 布局，首次使用请用设置页显示的路径核对一遍。
- 设备是 `OpenHarmony-4.1.7.5 / API 11`；`compileSdkVersion` 高于 11 的工程装得上也跑不了。
  商店自身与 transfer 用 API 10，其余入库应用用 API 11。
- UI 自动化（`uitest`）只能点坐标、没有文本输入，所以「填地址」这一步在批量场景下
  一律走预置文件，不靠手输；按钮坐标要 `uitest dumpLayout` 取，不能按截图估。
- `uitest uiInput click` 比 `uinput -T -d -u` 更可靠（后者常被当成滑动）。

## 7. 里程碑映射

对应 `ohos-device/docs/APP-ROADMAP.md` Phase 4：

| roadmap | 本仓对应 | 状态 |
| --- | --- | --- |
| M0 可行性冻结（`hdc install`/`save`/`zlib`/`request.agent`/验签） | `docs/DESIGN.md` §2、§5 | 方案定稿；验签（pinning）未做 |
| M1 索引与仓库（schema、build/validate、CI） | `tools/lib/index-lib.mjs`、`build-index.mjs`、`validate-index.mjs`、CI | 完成；6 个应用索引校验通过 |
| M2 设备端下载器 + 校验队列 | `app/…/pages/Index.ets`、`ReadyQueue.ets`、`StoreClient.ets` | **真机验证**（下载→SHA256） |
| M3 设备端静默安装 | `PrivilegedInstaller.ts` + `system_core` 签名 | **真机验证**（homeime、browser 自行安装成功） |
| M3b PC agent 兜底 | `agent/pc-agent.mjs` + `agent/lib/agent-lib.mjs` | **真机验证**（homekiosk、media 安装成功） |
| M4+（图标、镜像测速、签名固定、回滚） | — | 未开始 |

## 8. 后续（按优先级）

1. 替换占位图标，补 `icon`/截图字段；`meta.json` 已留位。
2. 索引与 HAP 增加 `signature`（解析签名链、固定 issuer/fingerprint），替代「只信 SHA256」。
3. 镜像回退（`mirrors` 模板）与断点续传（`serve.mjs` 已支持 Range）。
4. 自动构建：把各仓 `build-artifacts/entry-signed.hap` 收集到 `store/apps/`，
   跑 `tools/verify-store-haps.sh`，再重建索引。

已完成：卡片加载时查询已装版本。`bundleManager.getBundleInfoForSelf` 只能查自己，
查别的包要用 `bundleManager.getBundleInfo(bundleName, 0, 100)`（systemapi，公开 SDK
无 d.ts），并在 Profile 里加 `GET_BUNDLE_INFO_PRIVILEGED` ACL。实现见
`app/entry/src/main/ets/common/InstalledStore.ts`；查不到就保持「下载」，不影响安装。
