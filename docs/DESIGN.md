# 设计说明

## 1. 目标与边界

在 LHT16（OpenHarmony 4.1.7.5 / API 11）开发板上替代已失联的厂商分发中心
`com.laval.dispatchcenter`（后端 `dispatchcenter.laval.aidog.club` DNS 已失效、页面空白，
且它持有 `INSTALL_BUNDLE`、是 `system_core` 应用 —— 普通应用无法复刻）。

本仓只做**可复制、可审计、可离线**的三件事：

1. **索引**：`store/apps/` 收 HAP，生成并校验 `store/index.json`（`docs/INDEX-SPEC.md`）。
2. **设备端商店**：`com.local.appcenter` 浏览、搜索、下载、SHA256 校验，把 HAP 放进沙箱。
3. **PC agent**：`hdc file recv` 拉回、再校验、`hdc install -r` 安装、写回结果。

明确不做：

- 设备端直接安装任意 HAP。`@ohos.bundle.installer` 的安装能力需要
  `ohos.permission.INSTALL_BUNDLE`，那是 `system_core` APL + ACL 才有的权限；
  普通应用拿不到，也不该为了拿它去改系统分区。
- 在线支付、账号、推荐算法、灰度发布。
- 自动信任第三方签名。当前只信任「索引里声明的 SHA256」。

## 2. 为什么是「设备下载 + PC 安装」

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

这条链的关键取舍：

- 设备侧**只读网络**，不需要任何系统权限；越权安装的风险为零。
- 安装动作留在 PC，谁装了包、装的是哪份哈希，在 PC 终端有日志。
- 断网也能装：HAP 已经落在 `store/apps/`，PC 与设备只要 hdc 通。
- 代价是**需要一台 PC 常连**。这就是 roadmap 里 Phase 4「依赖 PC agent」的含义，
  不是没做完的临时状态。

## 3. 时序（一次安装）

1. 设备：商店地址来自 `Settings.ets`，或预置文件（见下）。
   `SettingsStore.loadEffective` 先读 preferences；为空则读
   `<filesDir>/appcenter/index-url.txt`（第一行 URL、第二行可选 PIN），读到后回写 preferences。
   批量部署不必在板上手输地址。
2. 设备：首页 `GET indexUrl?pin=…`（可选 PIN）。
   - 非 200 / 401 / `schemaVersion != 1` → 页面显示原文，不清空已有列表。
3. 用户点「下载」：
   - `StoreClient.resolveHapUrl` 用 `index.baseUrl`，为空则取 `indexUrl` 同目录。
   - `@ohos.request.downloadFile` 下载到 `<filesDir>/appcenter/cache/<bundle>-<versionCode>.hap`，
     等到 `complete` 事件（带 60 s 超时）。
   - `cryptoFramework` 分块 SHA256，与 `latest.sha256` 比对；不符即丢弃并提示。
4. 设备：`ReadyQueue.enqueue` 复制到 `ready/`，写 `ready/<requestId>.json`：
   ```json
   { "id": "...", "bundleName": "...", "versionCode": 1000000, "versionName": "1.0.0",
     "hap": "com.local.homekiosk-1000000.hap", "sizeBytes": 1234567,
     "sha256": "…", "requestedAt": "2026-…Z" }
   ```
   `requestId` 必须匹配 agent 的 `^[a-zA-Z0-9_-]{8,64}$`（**不含点**），所以设备端用
   `requestIdFor()` 把 bundleName 里的 `.` 等非法字符换成 `-`：
   `com.local.homekiosk` + `1000000` → `com-local-homekiosk-1000000-<epochMs>`。
5. PC：`pc-agent.mjs` 轮询 `ls ready/`：
   - `cat` 元数据 → 校验字段（`agent/lib/agent-lib.mjs::parseReadyMeta`）。
   - `hdc file recv` 拉回本地临时目录，重新算 SHA256（不信任设备侧结果）。
   - 不符 → 写 `done/<id>.result.json`，`status=failed`，不动设备。
   - 相符 → `hdc install -r`；成功则写 `status=installed` 并把 ready 文件移入 `done/`。
   - `9568332 sign info inconsistent`（设备上已有签名不同的同包名版本）→ 先
     `hdc uninstall` 再装一次，仍失败才写 `failed`。
6. 设备（可选）：读 `done/<id>.result.json` 显示最终状态。

`--dry-run` 会打印将执行的动作但不 recv/install，用于先核对路径与元数据。


## 4. 沙箱路径与 agent 参数

设备侧根目录是 `ctx.filesDir + '/appcenter'`，设置页会直接显示出来（可复制）。
PC 侧对应参数：

```
node agent/pc-agent.mjs --once --serial <serial> \
  --sandbox /data/app/el2/100/base/com.local.appcenter/haps/entry/files/appcenter
```

注意这是 **EL2 / 用户 100** 的沙箱路径；设备上以 `bm dump -n com.local.appcenter` 或设置页
显示的值为准。agent 默认值按同一约定写死，换包名/多用户时要显式传 `--sandbox`。

预置地址文件就在同一层：`<sandbox>/../index-url.txt`，即
`…/haps/entry/files/appcenter/index-url.txt`。仓库里的 `tools/dev-set-prefs.sh`
会写这个文件、修属主（`20010059:20010059`）、重启应用并截图：

```bash
bash tools/dev-set-prefs.sh http://192.168.31.100:8787/index.json
```

> 用 root 在设备上 `mkdir` 会造出 root 属主目录，应用随后会 `Permission denied`；
> 脚本已用 `chown -R` 兜住这一点。

### 4.1 构建、签名、部署（无 IDE）

`scripts/` 与 `ohos-kiosk` 同源，可直接用于本仓：

```bash
bash scripts/doctor.sh                # 17 项环境自检
bash scripts/make-signing-material.sh # signing/*.p12|cer|p7b（一次性）
bash scripts/build.sh                 # hvigor assembleHap -> entry-unsigned.hap
bash scripts/sign.sh                  # hap-sign-tool localSign + verify-app
OHOS_TARGET=<serial> bash scripts/deploy.sh
```

- 签名用 SDK 自带 `OpenHarmony.p12` 里的 **测试 PKI 根/中间 CA 私钥**，给
  `com.local.appcenter` 签一张 10 年证书，stock 镜像直接信任；不需要厂商证书。
- hvigor 3.2.4 靠 `NODE_PATH=$OHOS_TOOLS/hvigor-3.2.4/node_modules` 找到
  `@ohos/hvigor-ohos-plugin`；`env.sh` 已设置。
- API 切换：`$OHOS_BASE_SDK_HOME/openharmony` 是指向 4.0/4.1 的 junction，
  `10`/`11` 是版本号目录。改 API 时同步改 `app/build-profile.json5` 的
  `compileSdkVersion`/`compatibleSdkVersion`，再重跑 `build.sh`。

## 5. 安全

已做：

- 传输：SHA256 端到端校验（设备校验一次、PC 再校验一次），任何一环不符都不安装。
- 路径：`isSafeRelative` 拒绝绝对路径/`..`/反斜杠/NUL；agent 侧 `parseReadyMeta` 只接受
  合法 `bundleName`、正整数 `versionCode`、64 位小写 SHA256、`.hap` 文件名（取 basename，
  不接受路径穿越）。
- 服务：`serve.mjs` 只允许 GET/HEAD，路径拼接前先拒绝 `..`，可选 PIN 门。
- 权限：商店只申请 `ohos.permission.INTERNET`；不申请安装、不申请读写他人沙箱。

未做（明确欠账）：

- **签名验证**。当前不解析 HAP 的签名链，只比对索引给的 SHA256。索引若被篡改，
  等于信任被篡改。缓解手段是 LAN 内自建、PIN + 人工核对哈希；正式方案应校验
  OpenHarmony 应用签名并固定 issuer/fingerprint（附录 B 的 `signature` 字段留了位置）。
- **索引签名**。`index.json` 没有签名，靠 HTTPS 或内网可信。
- **回滚保护**。允许同 `versionCode` 覆盖安装（`hdc install -r`），未做防降级。
- **PIN 强度**。PIN 走明文 HTTP query/header，只防误连，不防抓包。

## 6. 已知环境限制（诚实记录）

- 2026-11-22 已在本机补齐工具链并**真机验证**：OpenHarmony 4.0 / 4.1 SDK、
  hdc 1.3.0a、hvigor 3.2.4、OpenJDK 17、hap-sign-tool；
  `scripts/{build,sign,deploy}.sh` 全链路跑通，商店首页在 LHT16 上正常渲染。
- 设备网络：`*.workers.dev`、`raw.githubusercontent.com` 不可达；GitHub Release 下载常失败。
  所以默认方案是 LAN 内 `node tools/serve.mjs`，不依赖公网。
- 上传到设备的路径依赖多用户/EL2 布局，首次使用请用设置页显示的路径核对一遍。
- 设备是 `OpenHarmony-4.1.7.5 / API 11`；`compileSdkVersion` 高于 11 的工程装得上也跑不了。
  商店自身与 transfer 用 API 10，其余入库应用用 API 11。
- UI 自动化（`uitest`）只能点坐标、没有文本输入，所以「填地址」这一步在批量场景下
  一律走预置文件，不靠手输。

## 7. 里程碑映射

对应 `ohos-device/docs/APP-ROADMAP.md` Phase 4：

| roadmap | 本仓对应 | 状态 |
| --- | --- | --- |
| M0 可行性冻结（`hdc install`/`save`/`zlib`/`request.agent`/验签） | `docs/DESIGN.md` §2、§5 | 方案定稿；验签未做 |
| M1 索引与仓库（schema、build/validate、CI） | `tools/lib/index-lib.mjs`、`build-index.mjs`、`validate-index.mjs`、CI | 完成；6 个应用索引校验通过 |
| M2 设备端下载器 + 校验队列 | `app/…/pages/Index.ets`、`ReadyQueue.ets`、`StoreClient.ets` | **真机验证**（下载→SHA256→入队） |
| M3 PC agent 安装闭环 | `agent/pc-agent.mjs` + `agent/lib/agent-lib.mjs` | **真机验证**（homekiosk、media 安装成功） |
| M4+（图标、镜像测速、签名、回滚） | — | 未开始 |

## 8. 后续（按优先级）

1. 替换占位图标，补 `icon`/截图字段；`meta.json` 已留位。
2. 索引与 HAP 增加 `signature`（解析签名链、固定 issuer/fingerprint），替代「只信 SHA256」。
3. 设备端读取 `done/` 结果，把「等待电脑安装」收敛成最终状态（已装/失败原因）。
4. 镜像回退（`mirrors` 模板）与断点续传（`serve.mjs` 已支持 Range）。
5. 自动构建：把各仓 `build-artifacts/entry-signed.hap` 收集到 `store/apps/` 并重建索引。
