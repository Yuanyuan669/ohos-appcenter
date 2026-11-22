# 签名、Profile 与特权安装

本仓的商店客户端不是普通应用：它申请了 `ohos.permission.INSTALL_BUNDLE`，
以 **`system_core`** 身份签名，从而能在设备上静默安装下载回来的 HAP。
本文记录这条链的材料、字段、验证方法与排错顺序。

## 1. 为什么必须这样签

`ohos.permission.INSTALL_BUNDLE` 的 `availableLevel` 是 `system_core`，比
`system_basic` 还高；普通（`normal`）应用连申请都申请不到，调用安装接口只会拿到
`201 permission denied`。

两条路对比：

| 方案 | 后果 |
| --- | --- |
| `apl=normal` | 只能把 HAP 放进 `ready/`，由 PC 上的 `agent/pc-agent.mjs` 执行 `hdc install -r` |
| `apl=system_core` + `hos_system_app` + ACL | 设备自己装，用户只看到「下载 → 已安装」 |

已验证：用 `system_core` 签出来的 HAP **照样通过 `bm install` 装进 `/data/app`**，
不需要预置进系统分区。也就是说这条路线没有 remount/OTA 风险；装错了卸载重装即可。

`normal` 变体仍然保留，作为权限模型的兜底（见 §4）。

## 2. 证书链

```
OpenHarmony Application Root CA        (根，公开测试 PKI)
└── OpenHarmony Application CA         (中间，私钥在 SDK 的 OpenHarmony.p12)
    └── App Center App                 (叶证书，本机签发，10 年)
```

SDK 的 `toolchains/lib/` 里自带 `OpenHarmony.p12`（根/中间 CA 的私钥）与
`OpenHarmonyProfileRelease.pem`（Profile 签名证书），所以 stock 开发者镜像直接信任
这条链，不需要厂商证书，也不需要 AppGallery 账号。

`scripts/make-signing-material.sh` 会重新生成一整套自洽材料（可重复执行）：

| 文件（`signing/`，git-ignored） | 用途 |
| --- | --- |
| `root-ca.cer` / `app-ca.cer` | 两级公开 CA 证书 |
| `appcenter.p12` | 商店自己的密钥对，alias `appcenter-app-key-v1` |
| `appcenter-app.cer` | 3 张证书的链：leaf → 中间 CA → 根 |
| `appcenter-profile.json` | 未签名 Profile，包着 bundle-name / apl / ACL |
| `appcenter-profile.p7b` | 用 Profile Release 密钥签过的 Profile |

> 每个仓都有自己的 `signing/`，且**包名以仓库 `scripts/env.sh` 的 `OHOS_BUNDLE` 为准**。
> 换包名或换机器时，必须重跑 `make-signing-material.sh`，否则会出现下文 §5 的
> `17700011`。

## 3. Profile 里起作用的字段

| 字段 | 本仓取值 | 作用 |
| --- | --- | --- |
| `bundle-info.bundle-name` | `com.local.appcenter` | 必须与 `AppScope/app.json5` 一致，否则设备拒装 |
| `bundle-info.apl` | `system_core` | 决定系统权限上限；`normal` 拿不到安装权限 |
| `bundle-info.app-feature` | `hos_system_app` | 声明为系统应用（`isSystemApp=true`） |
| `acls.allowed-acls` | `["ohos.permission.INSTALL_BUNDLE"]` | 允许 Profile 授予该 ACL |
| `app-distribution-type` | `os_integration` | 自签/预置分发 |
| `type` | `release` | 非调试 Profile |

这些值全部由 `scripts/env.sh` 的三个变量驱动，`make-signing-material.sh` 写进 Profile：

```bash
OHOS_APL=system_core
OHOS_APP_FEATURE=hos_system_app
OHOS_ALLOWED_ACLS=ohos.permission.INSTALL_BUNDLE
```

`module.json5` 里也必须申请同一个权限，ACL 与 `requestPermissions` 对不上会报
`9568289`：

```json5
"requestPermissions": [
  { "name": "ohos.permission.INTERNET" },
  { "name": "ohos.permission.INSTALL_BUNDLE", "reason": "$string:reason_install_bundle" }
]
```

## 4. 构建 normal 兜底变体

不想给商店系统身份时，可以整条链按普通应用签：

```bash
OHOS_APL=normal \
OHOS_APP_FEATURE=hos_normal_app \
OHOS_ALLOWED_ACLS= \
  bash scripts/make-signing-material.sh
bash scripts/build.sh && bash scripts/sign.sh && bash scripts/deploy.sh
```

此时 `PrivilegedInstaller.install()` 会返回 `201`，`Index.ets` 自动回退到
`ready/` + PC agent——功能降级，但不会报错。设备端会提示「已就绪，等待电脑侧 agent」。

## 5. 设备端验证身份

装好后确认设备真的给了系统身份与权限：

```bash
hdc shell bm dump -n com.local.appcenter | grep -E 'appPrivilegeLevel|isSystemApp|codePath'
hdc shell bm dump -n com.local.appcenter | grep -A4 '"reqPermissionStates"'
```

期望：

- `appPrivilegeLevel: system_core`
- `isSystemApp: true`
- `codePath: /data/app/...`（说明没动系统分区）
- `reqPermissionStates` 里 `INSTALL_BUNDLE` 对应 `0`（`0` = granted）

## 6. 发布前必须做的校验

`17700011` 最常见的成因不是签名工具坏了，而是 **HAP 内嵌 Profile 的包名和目录不一致**
（本仓真实踩过：`store/apps/com.local.browser/` 里的包，Profile 却写着
`com.local.transfer`）。用下面这个脚本拦住它：

```bash
bash tools/verify-store-haps.sh
```

它逐个 `verify-app` + `verify-profile`，要求：

1. 签名链验证通过；
2. `bundle-info.bundle-name` 与 `store/apps/<bundleName>/` 目录一致；
3. 打印 `apl / app-feature / allowed-acls / signer`，便于人工审计。

任何一条不合格就非 0 退出，**不要发布索引**。发布顺序：

```bash
bash tools/verify-store-haps.sh          # 包本身合格
node tools/build-index.mjs --store store --base-url http://<PC-IP>:8787
node tools/validate-index.mjs --store store
```

> 替换了某个 HAP 之后必须重建索引，否则索引里的 SHA256 还是旧包的；设备端会报
> 「SHA256 不符，已丢弃」。设备上要**重启或点「刷新」**才会拿到新索引。

## 7. 错误码与排错顺序

| 错误 | 含义 | 处理 |
| --- | --- | --- |
| `201` | 没有 `INSTALL_BUNDLE`（通常是 `normal` 包） | 检查 `bm dump` 的 `appPrivilegeLevel`；重新用 `system_core` 签 |
| `17700011` | HAP 签名/Profile 校验失败 | ① `tools/verify-store-haps.sh` 看包名；② 设备上已有**另一套证书**的同包名版本 → 先卸载再装（应用内已自动做）；③ Profile 有效期过了 |
| `17700001` | 要卸载的包不存在 | 正常：全新安装时会先尝试卸载旧版，忽略即可 |
| `17700047` | 同版本重装但 `installFlag` 没带 `REPLACE_EXISTING` | 传 `installFlag: 1`；4.1 只接受 `0` / `1` / `0x10`，传 `2`/`3` 会被当成非法值 |
| `9568289` | 签名材料不成套 / ACL 与 `requestPermissions` 不一致 | 重跑 `make-signing-material.sh`，并核对 ACL 列表 |
| `9568322` / `9568313` | 证书或 Profile 与设备/包名不匹配 | 同上；确认 `OHOS_BUNDLE` |
| `is not callable` | 调错了模块 | 安装器是独立 NAPI 模块 `@ohos.bundle.installer`，不是 `bundleManager` 的方法 |
| 安装后 `versionCode = 0` | `bm dump` 里的 `appQuickFix` 字段 | 看 `applicationInfo` 段，真正的版本号在后面 |

## 8. 实现备注（`app/…/common/PrivilegedInstaller.ts`）

- 公开 SDK 的 `ets/api` 把 `@ohos.bundle.installer` 的 `d.ts` 裁掉了，因此用 `.ts`
  文件 + `// @ts-ignore` 加载；`.ets` 的 ArkTS 校验不允许这种动态调用。
- 4.1 上 `getBundleInstaller()` 返回 Promise，必须 `await`。
- 安装参数必须显式带 `userId: 100`（设备上的默认用户）。
- 安装顺序：直接装 → 失败带 `installFlag: 1`（`REPLACE_EXISTING`，允许同版本覆盖）
  再试 → 仍报 `17700011` 则 `uninstall` 后重装。**第三步会清空目标应用数据**，只在
  跨证书迁移时发生。
- 4.1 的 `InstallFlag` 枚举只有 `NORMAL=0`、`REPLACE_EXISTING=1`、`FREE_INSTALL=0x10`。
  `installer.cpp` 对其它值直接判定非法并退回默认值，于是同版本重装会报 `17700047`
  ——这是最初踩到的坑，不是版本号逻辑本身的问题。
