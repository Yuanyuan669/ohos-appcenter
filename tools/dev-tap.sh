#!/usr/bin/env bash
# 设备联调：重启商店 -> dump UI 布局 -> 点第 N 个「下载/重试」-> 打印 hilog。
#
#   bash tools/dev-tap.sh [index]
#
# index 从 0 开始，按页面上按钮的先后顺序。必须重启应用，否则内存里可能还是
# 旧索引（会导致误报「SHA256 不符」）。
set -u
export MSYS_NO_PATHCONV=1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/common.sh"

INDEX=${1:-0}
BUNDLE=${2:-}
REMOTE_LAYOUT=/data/local/tmp/appcenter-layout.json
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

require_device

step "唤醒并解锁"
hdc_run shell "power-shell wakeup" >/dev/null 2>&1 || true
hdc_run shell "uinput -T -m 540 2000 540 500 250" >/dev/null 2>&1 || true
sleep 1

step "重启 $OHOS_BUNDLE"
hdc_run shell "aa force-stop $OHOS_BUNDLE" >/dev/null 2>&1 || true
sleep 1
hdc_run shell "aa start -a $OHOS_ABILITY -b $OHOS_BUNDLE" >/dev/null
sleep 6

step "读取 UI 布局"
hdc_run shell "uitest dumpLayout -p $REMOTE_LAYOUT" >/dev/null
hdc_run file recv "$REMOTE_LAYOUT" "$(cygpath -w "$TMP/layout.json")" >/dev/null

xy=$("$OHOS_NODE" "$(cygpath -w "$OHOS_PROJECT_ROOT/tools/click-bounds.mjs")" \
      "$(cygpath -w "$TMP/layout.json")" "$INDEX") \
  || fail "没有找到可点击的「下载/重试」按钮（布局见 $TMP/layout.json）"
ok "tap: $xy"

step "点击"
hdc_run shell "uitest uiInput click $xy" >/dev/null
sleep 25

step "应用日志（最后 6 行）"
hdc_run shell "hilog -x -T AppCenter | tail -n 6"

echo
if [ -n "$BUNDLE" ]; then
  step "设备上的 $BUNDLE"
  hdc_run shell "bm dump -n $BUNDLE | grep -E '\"versionName\": \"[^\"]+\"|\"versionCode\": [1-9]' | head -4" \
    || echo "（未安装）"
fi
