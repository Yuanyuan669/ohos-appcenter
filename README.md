# ohos-appcenter — 开发板应用中心

`com.local.appcenter`：给 LHT16（OpenHarmony 4.1.7.5 / API 11）做的一个**可离线、可审计**的应用分发闭环，
用来替代已失联的厂商「分发中心」（`com.laval.dispatchcenter`）。

三块：

| 目录 | 作用 |
| --- | --- |
| `store/` | HAP 仓库 + `index.json`（schema v1） |
| `tools/` | 建索引、校验、局域网静态服务、工程结构自检 |
| `app/` | 设备端 ArkTS 应用（浏览 / 下载 / SHA256 校验 / 入队） |
| `agent/` | PC 侧 agent：`hdc` 拉取、复核哈希、`hdc install -r` |

**设备端不安装任何东西** —— 普通应用没有 `INSTALL_BUNDLE` 权限，装包必须由 PC 侧 agent 执行。
这是设计前提，不是未完成项，原因见 [docs/DESIGN.md](docs/DESIGN.md)。

## 当前状态（2026-11-22）

| 项 | 状态 |
| --- | --- |
| 索引构建 / 校验 | ✅ 通过单测（`node --test`，12 项） |
| 设备端 ArkTS | ⚠️ 代码完成，**未编译、未真机验证**（本机无 SDK/hdc） |
| PC agent | ⚠️ 纯逻辑有单测；`hdc` 真机调用未跑 |
| `store/apps/` | 空（本机无法构建 HAP） |

不要把它当成「已验证可用」的成品：索引与工具链可以现在就用，应用侧需要一台有 SDK 的机器先编译。
`app/…/media/app_icon.png` 目前沿用 `ohos-kiosk` 的占位图，正式发布前应替换。

## 快速开始

### 1. 生成并校验索引

```bash
cd ohos-appcenter
node tools/build-index.mjs --store store
node tools/validate-index.mjs --store store
```

空仓库时得到 0 个应用的合法索引。放应用：

```
store/apps/<bundleName>/<versionCode>/
  meta.json
  <任意文件名>.hap
```

`meta.json` 必填 `name` / `summary` / `versionName`，其余可选；完整字段见
[docs/INDEX-SPEC.md](docs/INDEX-SPEC.md)。

### 2. 局域网起服务

```bash
node tools/serve.mjs --store store --port 8787
# 需要 PIN 时：
node tools/serve.mjs --store store --port 8787 --pin 123456
```

会打印 `http://<本机 IP>:8787/index.json`，把它填进设备端「设置 → 商店地址」；
填了 PIN 后设备会自动以 `?pin=…` 带上（`X-Store-Pin` 头也接受，方便 curl）。
只允许 GET/HEAD，HAP 支持 Range（断点续传）。

### 3. 装到设备

```bash
# 设备侧沙箱目录（设置页会显示，通常如下）
# /data/app/el2/100/base/com.local.appcenter/haps/entry/files/appcenter

node agent/pc-agent.mjs --once --serial <serial> \
  --sandbox /data/app/el2/100/base/com.local.appcenter/haps/entry/files/appcenter
# 先看要做什么、不动设备：
node agent/pc-agent.mjs --once --dry-run
# 常驻，每 5 s 轮询：
node agent/pc-agent.mjs --interval 5
```

成功结果写回设备 `done/<id>.result.json`（`status=installed|failed`）。

## 环境变量

与 `ohos-device` 保持一致（约定见 `ohos-device/docs/ENVIRONMENT.md` §零）：

| 变量 | 用途 |
| --- | --- |
| `OHOS_HDC` | 指定 `hdc` 可执行文件（优先级最高） |
| `OHOS_TOOLS` | 工具链根，回退找 `sdk/openharmony/toolchains/hdc.exe` |
| `OHOS_JDK` | 构建时使用的 JDK（`app/` 编译需要） |

`agent/pc-agent.mjs` 解析顺序：`--hdc` → `OHOS_HDC` → `OHOS_TOOLS` → PATH。

## 常用命令

```bash
node --test                          # 全部单测
node tools/check-app-json.mjs        # 工程结构自检（不编译）
node tools/build-index.mjs --help
node tools/serve.mjs --help
node agent/pc-agent.mjs --help
```

## 目录

```
app/
  AppScope/            bundleName = com.local.appcenter
  entry/src/main/ets/
    common/            SettingsStore / StoreClient / ReadyQueue / Logger
    model/Types.ets    与 index.json schema 一一对应
    pages/             Index（列表+下载）、Settings（地址+PIN）
    entryability/      EntryAbility
tools/
  lib/index-lib.mjs    扫描/哈希/构建/校验（纯逻辑）
  build-index.mjs      生成 store/index.json
  validate-index.mjs   校验（含文件哈希）
  serve.mjs            局域网静态服务（Range + 可选 PIN）
  check-app-json.mjs   json5 解析 + 页面/ability 路径存在性
agent/
  lib/agent-lib.mjs    ready 解析 / sha256 / 结果拼装
  pc-agent.mjs         轮询 + hdc recv/install
docs/
  DESIGN.md            架构、时序、安全、限制、里程碑
  INDEX-SPEC.md        schema v1 与不变量
```

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。

## 相关

- 调研与厂商分发中心分析：`ohos-device/docs/research/APP-APPCENTER.md`
- 分发链路里程碑：`ohos-device/docs/APP-ROADMAP.md` Phase 4
