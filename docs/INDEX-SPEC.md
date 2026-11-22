# 索引规范（schema v1）

`store/index.json` 是设备端唯一读取的契约。PC 侧 `tools/build-index.mjs` 从
`store/apps/` 生成它，`tools/validate-index.mjs` 与 CI 校验它；设备端
`app/entry/src/main/ets/model/Types.ets` 的接口与本文一一对应。

设计参考：`ohos-device/docs/research/APP-APPCENTER.md` 附录 B。差异写在最后一节。

## 1. 目录约定

```
store/
  index.json                      <- 生成物，入库
  apps/
    <bundleName>/
      <versionCode>/              <- 十进制整数，必须能解析为 > 0
        meta.json                 <- 人工维护
        <any-name>.hap             <- 恰好 1 个
```

不变量：

1. 每个 `apps/<bundle>/<versionCode>/` 目录**恰好一个** `.hap`；0 个或多个都报错。
2. `versionCode` 目录名必须是正整数，且与 `meta.json` 里的 `versionName` 一起代表一个版本。
3. 同一 `bundleName` 可以有多个版本目录；索引里 `latest` 取 `versionCode` 最大者。
4. 索引中 `latest.hap` 是**仓内相对路径**（`apps/...`），不含盘符、不含 `..`、不用反斜杠。
5. `sha256` 与 `sizeBytes` 由生成器实测写入，不允许手填；`validate-index.mjs` 会重新计算比对。

## 2. `meta.json`（人工维护，每个版本一份）

```jsonc
{
  "name": "应用中心",              // 必填，列表主标题
  "summary": "索引 + 下载 + PC 安装", // 必填，一行摘要
  "versionName": "0.1.0",          // 必填，展示用版本号
  "category": "工具",              // 可选，默认「其他」
  "description": "……",             // 可选，详情页正文
  "developer": "local",            // 可选，默认 local
  "license": "Apache-2.0",         // 可选
  "source": "https://…",           // 可选，源码地址
  "tags": ["工具"],                // 可选
  "deviceTypes": ["default", "phone", "tablet"], // 可选
  "minAPIVersion": 10,             // 可选，默认 10
  "targetAPIVersion": 11,          // 可选，默认 11
  "publishedAt": "2026-11-22T00:00:00Z", // 可选
  "releaseNotes": "首个版本"        // 可选
}
```

`versionCode` 不写在 `meta.json` 里 —— 以目录名为准，避免两处不一致。

## 3. `index.json`（生成物）

```jsonc
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-22T00:00:00.000Z",
  "channel": "stable",
  "minAppVersionCode": 1,
  "baseUrl": "http://192.168.31.27:8787",
  "mirrors": [
    { "id": "direct", "name": "直连", "template": "" }
  ],
  "apps": [
    {
      "bundleName": "com.local.homekiosk",
      "name": "HomeKiosk",
      "summary": "家庭信息屏",
      "description": "",
      "developer": "local",
      "license": "Apache-2.0",
      "source": "",
      "category": "工具",
      "tags": [],
      "deviceTypes": ["default", "phone", "tablet"],
      "latest": {
        "versionName": "1.0.0",
        "versionCode": 1000000,
        "minAPIVersion": 10,
        "targetAPIVersion": 11,
        "sizeBytes": 1234567,
        "sha256": "0123…（64 位小写）",
        "hap": "apps/com.local.homekiosk/1000000/entry-signed.hap",
        "publishedAt": "2026-11-16T00:00:00Z",
        "releaseNotes": "",
        "installMode": "hdc"
      },
      "versions": [
        {
          "versionName": "1.0.0",
          "versionCode": 1000000,
          "sizeBytes": 1234567,
          "sha256": "0123…",
          "hap": "apps/com.local.homekiosk/1000000/entry-signed.hap",
          "publishedAt": "2026-11-16T00:00:00Z"
        }
      ],
      "revoked": false
    }
  ]
}
```

### 字段语义

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `schemaVersion` | 是 | 固定 `1`。设备端不等于 1 直接拒收。 |
| `generatedAt` | 是 | ISO 8601。 |
| `channel` | 否 | `stable` / `beta`，生成时传入。 |
| `minAppVersionCode` | 否 | 低于此 `versionCode` 的商店客户端应提示升级（当前未强制）。 |
| `baseUrl` | 否 | HAP 所在站点根，例如 LAN 服务地址；为空则按 `indexUrl` 同目录推导。 |
| `mirrors` | 否 | 备用下载模板；当前设备端只用 `baseUrl`，镜像回退留作后续。 |
| `apps[].bundleName` | 是 | 唯一键，格式 `^[a-zA-Z][a-zA-Z0-9._-]{2,}$`。 |
| `apps[].latest` | 是 | 最新版本，`versions[0]` 必须等于它。 |
| `apps[].versions` | 是 | 按 `versionCode` **降序**。 |
| `apps[].revoked` | 是 | 停用标记；当前生成器恒为 `false`，设备端未实现拦截。 |
| `latest.sha256` | 是 | 64 位小写十六进制。设备下载后必须比对，不符即丢弃。 |
| `latest.hap` | 是 | 相对路径，仅 `.hap`。 |
| `latest.installMode` | 是 | 目前只有 `hdc`：设备端不安装，由 PC agent 执行。 |

## 4. 校验规则（`validate-index.mjs` 实际执行）

- `schemaVersion === 1`；`generatedAt` 非空；`apps` 是数组。
- 每个 `bundleName` 合法且不重复；`name`、`summary`、`latest` 齐备。
- `latest.versionCode` 为 `>0` 整数；`sizeBytes` 为 `>0` 整数；`sha256` 匹配 `^[0-9a-f]{64}$`。
- `latest.hap` 过 `isSafeRelative`（拒绝 `..`、绝对路径、反斜杠、NUL），且以 `.hap` 结尾。
- 文件级校验（默认开启）：HAP 存在、实际大小与 `sizeBytes` 一致、实际 SHA256 与索引一致。
- `versions` 降序；`versions[0].versionCode === latest.versionCode`。

`--no-files` 可跳过文件级校验（仅结构检查，CI 之外快速跑用）。

## 5. 与调研文档附录 B 的差异

| 项 | 附录 B（调研稿） | 本仓 v1（已实现） |
| --- | --- | --- |
| 应用主键 | `id` 与 `bundleName` 并存 | 只用 `bundleName`，避免两个 ID 漂移 |
| 下载地址 | 每条带 `downloadUrl` 全 URL | 只存 `hap` 相对路径 + 顶层 `baseUrl`，换 IP 不用重生成 |
| 签名描述 | `signature{scheme,subject,issuer,fingerprintSha256,notAfter}` | **未实现**；设备端目前只校验 SHA256，见 `docs/DESIGN.md` §安全 |
| `abi` / `deviceTypes` in latest | 有 | `deviceTypes` 提到应用级；`abi` 未做（单 HAP 方案） |
| `icon` | `icons/...png` | **未实现**；列表先用文字卡 |
| `revoked` | 有 | 字段保留，生成器恒 `false`，设备端未拦截 |

这些差异不是遗漏，是 MVP 范围的明确裁剪；补齐顺序写在 `docs/DESIGN.md` §后续。
