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

1. 设备：`Settings.ets` 保存 `indexUrl`（如 `http://192.168.31.27:8787/index.json`）与可选 PIN。
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
5. PC：`pc-agent.mjs` 轮询 `ls ready/`：
   - `cat` 元数据 → 校验字段（`agent/lib/agent-lib.mjs::parseReadyMeta`）。
   - `hdc file recv` 拉回本地临时目录，重新算 SHA256（不信任设备侧结果）。
   - 不符 → 写 `done/<id>.result.json`，`status=failed`，不动设备。
   - 相符 → `hdc install -r`；成功则写 `status=installed` 并把 ready 文件移入 `done/`。
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

- 编写本仓时这台机器**没有 DevEco Studio、没有 OpenHarmony SDK、没有 `hdc`**
  （`where hdc` 为空），因此：
  - ArkTS 代码**未经编译**，错误只经人工静态检查；`tools/check-app-json.mjs` 只校验工程结构。
  - `store/apps/` 里没有真实 HAP；索引当前为空。
  - agent 的 `hdc` 调用路径未端到端跑过，只有纯逻辑单测（`node --test`，12 项）。
- 设备网络：`*.workers.dev`、`raw.githubusercontent.com` 不可达；GitHub Release 下载常失败。
  所以默认方案是 LAN 内 `node tools/serve.mjs`，不依赖公网。
- 上传到设备的路径依赖多用户/EL2 布局，首次使用请用设置页显示的路径核对一遍。

## 7. 里程碑映射

对应 `ohos-device/docs/APP-ROADMAP.md` Phase 4：

| roadmap | 本仓对应 | 状态 |
| --- | --- | --- |
| M0 可行性冻结（`hdc install`/`save`/`zlib`/`request.agent`/验签） | `docs/DESIGN.md` §2、§5 | 方案定稿；验签未做 |
| M1 索引与仓库（schema、build/validate、CI） | `tools/lib/index-lib.mjs`、`build-index.mjs`、`validate-index.mjs`、CI | 完成并通过单测 |
| M2 设备端下载器 + 校验队列 | `app/…/pages/Index.ets`、`ReadyQueue.ets`、`StoreClient.ets` | 代码完成，**未编译/未真机** |
| M3 PC agent 安装闭环 | `agent/pc-agent.mjs` + `agent/lib/agent-lib.mjs` | 逻辑完成 + 单测；未接真机 |
| M4+（图标、镜像测速、签名、回滚） | — | 未开始 |

## 8. 后续（按优先级）

1. **在一台有 SDK 的机器上编译 HAP**，把 `com.local.appcenter` 装到板子，跑通 M2。
2. 用真实 HAP 填 `store/apps/`，跑 `build-index` + `validate`，让首页有内容。
3. agent 真机联调：确认沙箱路径、`hdc file recv` 与 `install -r` 的返回文本。
4. 加 `icon` 与 `signature` 校验（先解析再固定 issuer/fingerprint）。
5. 镜像回退（`mirrors` 模板）与断点续传（`serve.mjs` 已支持 Range）。
