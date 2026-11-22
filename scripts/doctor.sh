#!/usr/bin/env bash
# Read-only preflight for the store client build chain.
#   bash scripts/doctor.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

FAILED=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else warn "$label"; FAILED=$((FAILED+1)); fi
}

step "1. 构建主机基础工具"
NODE="$(resolve_node || true)"
if [ -n "$NODE" ]; then ok "node -> $NODE ($("$NODE" -v))"; else warn "node 缺失"; fi
if "$JAVA_BIN" -version >/dev/null 2>&1; then
  ok "java -> $JAVA_BIN ($("$JAVA_BIN" -version 2>&1 | head -1))"
else
  warn "java 缺失（export JAVA_HOME=<jdk17>）"; FAILED=$((FAILED+1))
fi

step "2. OpenHarmony SDK（API 10）"
check "toolchains -> $OHOS_SDK_TOOLCHAINS" test -d "$OHOS_SDK_TOOLCHAINS"
if [ -f "$OHOS_SDK_TOOLCHAINS/oh-uni-package.json" ]; then
  ok "SDK $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$OHOS_SDK_TOOLCHAINS/oh-uni-package.json" | head -1)"
fi
check "hvigor 需要的版本号目录 $OHOS_BASE_SDK_HOME/10" test -d "$OHOS_BASE_SDK_HOME/10"

step "3. hdc 与签名工具"
if [ -n "$HDC_BIN" ]; then ok "hdc -> $HDC_BIN"; else warn "hdc 缺失"; FAILED=$((FAILED+1)); fi
check "hap-sign-tool -> $OHOS_SDK_TOOLCHAINS/lib/hap-sign-tool.jar" test -f "$OHOS_SDK_TOOLCHAINS/lib/hap-sign-tool.jar"

step "4. hvigor"
check "hvigor CLI -> $HVIGOR_CLI" test -f "$HVIGOR_CLI"
check "NODE_PATH 插件目录 -> $NODE_PATH" test -d "$NODE_PATH"

step "5. 签名材料（$OHOS_SIGN_DIR）"
check "keystore $OHOS_KEYSTORE" test -f "$OHOS_KEYSTORE"
check "cert     $OHOS_APP_CERT" test -f "$OHOS_APP_CERT"
check "profile  $OHOS_PROFILE" test -f "$OHOS_PROFILE"
echo "         缺材料时跑 bash scripts/make-signing-material.sh"

step "6. 工程 API 配套"
PROF="$OHOS_APP_DIR/build-profile.json5"
[ -f "$PROF" ] && ok "$(grep -oE '"(compile|compatible)SdkVersion": *[0-9]+' "$PROF" | tr '\n' ' ')"
if [ -n "$HDC_BIN" ]; then
  T=$(hdc_run list targets 2>/dev/null | tr -d '\r' | grep -v '[Empty]' | head -1)
  [ -n "$T" ] && ok "设备在线：$T" || warn "没有设备（部署前再插 USB 或设 OHOS_TARGET）"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "${C_OK}检查完成：全部通过。${C_OFF}"
else
  echo "${C_WARN}检查完成：$FAILED 项待补。${C_OFF}"
fi
