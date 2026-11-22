# ohos-appcenter — 开发板应用中心

`com.local.appcenter`：给 LHT16（OpenHarmony 4.1.7.5 / API 11）做的一个**可离线、可审计**的应用分发闭环，
用来替代已失联的厂商「分发中心」（`com.laval.dispatchcenter`）。

组成：

| 目录 | 作用 |
| --- | --- |
| `store/` | HAP 仓库 + `index.json`（schema v1） |
| `tools/` | 建索引、校验、发布前 HAP 验签、局域网静态服务、工程结构自检 |
| `app/` | 设备端 ArkTS 应用（浏览 / 下载 / SHA256 校验 / **本机静默安装**） |
| `agent/` | PC 侧 agent：`hdc` 拉取、复核哈希、`hdc install -r`（仅在 `normal` 兜底变体中使用） |
| `scripts/` | 无 IDE 的构建/签名/部署链（doctor / build / sign / deploy） |

商店客户端以 **`system_core`** 身份签名、持有 `ohos.permission.INSTALL_BUNDLE`，
所以「点下载 → 设备自己装」，不需要电脑在场；整个安装发生在 `/data/app`，
不碰系统分区。签名链、Profile 字段与排错见 [docs/SIGNING.md](docs/SIGNING.md)。
只有按 `normal` 身份构建时才会退回「设备入队 + PC agent」的兜底路径。

## 当前状态（2026-11-23，本机真机验证）

| 项 | 状态 |
| --- | --- |
| 索引构建 / 校验 | ✅ `node --test` 通过；`build-index` + `validate-index` 对 6 个应用通过 |
| 设备端 ArkTS | ✅ 4.1 SDK 编译、`system_core` 自签、安装到 LHT16（`isSystemApp=true`，`INSTALL_BUNDLE` 已授予） |
| 设备端静默安装 | ✅ 真机闭环：商店内点「下载」→ 校验 → 设备自行安装成功（homeime、browser），全程无 PC agent、无弹窗 |
| 发布前验签 | ✅ `tools/verify-store-haps.sh` 对 6 个 HAP 全部通过（含 Profile 包名比对） |
| PC agent | ✅ 兜底路径可用：`--once` 真机安装 `homekiosk` 与 `media` 成功（含哈希复核） |
| `store/apps/` | ✅ 6 个应用：HomeKiosk、媒体、浏览器、快传、沐界输入法、网易云音乐 |
| 构建 / 签名 / 部署脚本 | ✅ `scripts/` 一条命令链，不依赖 IDE |

已入库的 6 个应用（都由本机 4.x SDK 编译、OpenHarmony 测试 PKI 自签，并已安装验证）：

| bundleName | 版本 | HAP |
| --- | --- | --- |
| `com.local.homekiosk` | 1.0.0 | 1.3 MB |
| `com.local.media` | 1.0.0 | 3.3 MB |
| `com.local.browser` | 1.0.0 | 1.1 MB |
| `com.local.transfer` | 1.0.0 | 1001 KB |
| `com.local.homeime` | 0.1.0 | 4.6 MB |
| `com.local.music` | 0.2.0 | 160 KB |

`app/…/media/app_icon.png` 仍是占位图，正式发布前应替换。


## 快速开始

### 1. 构建 / 签名 / 部署设备端应用

工具链与签名说明见 `ohos-device/docs/ENVIRONMENT.md` §1.1。每台机器只在
`scripts/env.local.sh` 里改路径（可从 `scripts/env.local.sh.example` 复制），其余走默认：

```bash
cd ohos-appcenter
bash scripts/doctor.sh                 # 环境自检（SDK / hdc / hvigor / JDK / 签名材料）
bash scripts/make-signing-material.sh  # 首次/换机：为 com.local.appcenter 签发证书 + Profile
bash scripts/build.sh                  # -> build-artifacts/entry-unsigned.hap
bash scripts/sign.sh                   # -> build-artifacts/entry-signed.hap（verify 自检）
OHOS_TARGET=<serial|IP:PORT> bash scripts/deploy.sh   # 安装 + 启动 + pidof + 截图 + hilog
```

`scripts/env.sh` 默认按 `system_core` 签（`OHOS_APL` / `OHOS_APP_FEATURE` /
`OHOS_ALLOWED_ACLS`），这样商店才能静默安装。改成 `OHOS_APL=normal` 后重跑
`make-signing-material.sh` 即得到「入队 + PC agent」的普通应用变体，详见
[docs/SIGNING.md](docs/SIGNING.md) §4。

`deploy.sh` 先 `install -r` 覆盖安装（保留沙箱数据）；只有签名/Profile 变了导致覆盖
失败时才卸载重装，并提示重新预置商店地址。

工程同时能编 API 10 与 API 11：`$OHOS_BASE_SDK_HOME/openharmony` 是指向
`openharmony-4.0-Release`（10）或 `openharmony-4.1-Release`（11）的 junction，
`$OHOS_BASE_SDK_HOME/10`、`/11` 是对应的 API 号目录。切 API 前先对好
`app/build-profile.json5` 里的 `compileSdkVersion` / `compatibleSdkVersion`。
本仓库自身是 10；商店里的 media/browser/homeime/music 是 11。

### 2. 生成并校验索引

```bash
cd ohos-appcenter
bash tools/verify-store-haps.sh              # 发布前必做：验签 + Profile 包名比对
node tools/build-index.mjs --store store --base-url http://192.168.31.100:8787
node tools/validate-index.mjs --store store
```

放应用：

```
store/apps/<bundleName>/<versionCode>/
  meta.json
  <任意文件名>.hap
```

`meta.json` 必填 `name` / `summary` / `versionName`，其余可选；完整字段见
[docs/INDEX-SPEC.md](docs/INDEX-SPEC.md)。把各仓 `build-artifacts/entry-signed.hap`
复制进来再重建索引即可。

> 换掉某个 HAP 后必须重建索引（`index.json` 里存的是旧包的 SHA256），且设备上要
> **重启应用或点「刷新」** 才会拿到新索引，否则会显示「SHA256 不符，已丢弃」。

### 3. 局域网起服务

```bash
node tools/serve.mjs --store store --port 8787 --host 0.0.0.0
# 需要 PIN 时：
node tools/serve.mjs --store store --port 8787 --host 0.0.0.0 --pin 123456
```

会打印 `http://<本机 IP>:8787/index.json`。只允许 GET/HEAD，HAP 支持 Range（断点续传）。

### 4. 设备端配置商店地址

两条路径，任选其一：

- 手动：应用内「设置 → 商店地址 / PIN」。
- 预置（批量部署用）：把 `<filesDir>/appcenter/index-url.txt` 推进沙箱，
  第一行 URL、第二行可选 PIN；应用启动时 preferences 为空就读它并回写。
  仓库里封装成：

```bash
bash tools/dev-set-prefs.sh http://192.168.31.100:8787/index.json
# 可选第三参数：PNG/JPEG 截图输出路径
```

> 设备沙箱目录默认 `/data/app/el2/100/base/com.local.appcenter/haps/entry/files`。
> 沙箱 uid 由系统在安装时分配，**重装会变**；脚本会从 `files/` 的属主动态取 uid，
> 再 `chown -R`，否则应用会 `Permission denied`。

### 5. 安装链路

默认路径（`system_core` 变体）：用户点「下载」后，设备完成下载 + SHA256 校验，
直接调用系统安装器安装，卡片变为「已安装 vX.Y.Z」。实现见
`app/entry/src/main/ets/common/PrivilegedInstaller.ts`；安装策略是
「直装 → `REPLACE_EXISTING` 重试 → 签名冲突才卸载重装」。

兜底路径（`OHOS_APL=normal` 构建，或安装接口返回 `201`）：HAP 被放进
`<filesDir>/appcenter/ready/`，由 PC agent 安装：

```bash
node agent/pc-agent.mjs --once --serial <serial> \
  --sandbox /data/app/el2/100/base/com.local.appcenter/haps/entry/files/appcenter
# 先看要做什么、不动设备：
node agent/pc-agent.mjs --once --dry-run
# 常驻，每 5 s 轮询：
node agent/pc-agent.mjs --interval 5
```

成功结果写回设备 `done/<id>.result.json`（`status=installed|failed`）。
若设备上已有**签名不同**的同包名版本（例如之前用调试证书装过），
`install -r` 会返回 `9568332 sign info inconsistent`；agent 会自动卸掉重装。

真机联调辅助（需要设备已授权调试、`uitest` 可用）：

```bash
bash tools/dev-tap.sh 0                       # 重启商店 -> 点第 1 个「下载/重试」-> 打印 hilog
bash tools/dev-tap.sh 1 com.local.homeime     # 同时打印目标包的版本
bash tools/dev-snap.sh out.jpeg               # 设备截图
```


## 环境变量

与 `ohos-device` 保持一致（约定见 `ohos-device/docs/ENVIRONMENT.md` §零）：

| 变量 | 用途 |
| --- | --- |
| `OHOS_HDC` | 指定 `hdc` 可执行文件（优先级最高） |
| `OHOS_TOOLS` | 工具链根，回退找 `sdk/`、`hvigor-3.2.4/`、`java/jdk-17/` |
| `OHOS_BASE_SDK_HOME` | SDK 根（含 `openharmony/`、`10/`、`11/`），默认 `$OHOS_TOOLS/sdk` |
| `DEVECO_HOME` | DevEco Studio 目录，只用它自带的 node |
| `JAVA_HOME` / `OHOS_JDK` | 构建与签名用的 JDK 17 |
| `OHOS_TARGET` | 设备 serial 或 `IP:PORT`，不设则用 hdc 报的第一个设备 |
| `OHOS_APL` | Profile 的 `apl`，默认 `system_core`；设 `normal` 得到兜底变体 |
| `OHOS_APP_FEATURE` | Profile 的 `app-feature`，默认 `hos_system_app` |
| `OHOS_ALLOWED_ACLS` | Profile 的 `allowed-acls`，默认 `ohos.permission.INSTALL_BUNDLE` |

`agent/pc-agent.mjs` 解析顺序：`--hdc` → `OHOS_HDC` → `OHOS_TOOLS` → PATH。
`scripts/env.sh` 按同样顺序定位，并强制把 `NODE_PATH` 指向
`$OHOS_TOOLS/hvigor-3.2.4/node_modules`（`hvigorfile.ts` 里是裸 require）。

## 常用命令

```bash
node --test                                  # 全部单测
node tools/check-app-json.mjs                # 工程结构自检（不编译）
bash tools/verify-store-haps.sh              # 发布前验签 + Profile 包名比对
node tools/build-index.mjs --store store --dry-run
node tools/build-index.mjs --store store --base-url http://<PC-IP>:8787
node tools/validate-index.mjs --store store
node tools/serve.mjs --store store --port 8787 --host 0.0.0.0
node agent/pc-agent.mjs --once --dry-run
bash tools/dev-set-prefs.sh                  # 推预置地址并重启 + 截图
```


## 目录

```
app/
  AppScope/            bundleName = com.local.appcenter
  entry/src/main/ets/
    common/            SettingsStore / StoreClient / ReadyQueue / PrivilegedInstaller / Logger
    model/Types.ets    与 index.json schema 一一对应
    pages/             Index（列表+下载+安装）、Settings（地址+PIN）
    entryability/      EntryAbility
scripts/               无 IDE 构建链：doctor / build / sign / deploy / 签名材料
signing/               本机生成，git-ignored（p12 / cer / p7b）
store/
  apps/<bundle>/<ver>/ meta.json + HAP（入库）
  index.json           生成物（入库）
tools/
  lib/index-lib.mjs    扫描/哈希/构建/校验（纯逻辑）
  build-index.mjs      生成 store/index.json
  validate-index.mjs   校验（含文件哈希）
  verify-store-haps.sh 发布前验签 + Profile 包名比对
  serve.mjs            局域网静态服务（Range + 可选 PIN）
  check-app-json.mjs   json5 解析 + 页面/ability 路径存在性
  dev-set-prefs.sh     推预置商店地址 + 重启 + 截图（设备调试）
  dev-tap.sh           重启商店 + 点第 N 个下载按钮 + 打印 hilog（设备调试）
  dev-snap.sh          设备截图
  click-bounds.mjs     从 uitest dumpLayout 结果里算按钮坐标
agent/
  lib/agent-lib.mjs    ready 解析 / sha256 / 结果拼装
  pc-agent.mjs         轮询 + hdc recv/install（normal 兜底；签名冲突自动卸装）
docs/
  DESIGN.md            架构、时序、安全、限制、里程碑
  SIGNING.md           证书链、Profile 字段、特权安装与错误码
  INDEX-SPEC.md        schema v1 与不变量
```


## 许可

Apache-2.0，见 [LICENSE](LICENSE)。

## 相关

- 调研与厂商分发中心分析：`ohos-device/docs/research/APP-APPCENTER.md`
- 分发链路里程碑：`ohos-device/docs/APP-ROADMAP.md` Phase 4
