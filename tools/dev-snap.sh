#!/usr/bin/env bash
# 设备截图 -> 本地文件。
#
#   bash tools/dev-snap.sh [输出路径]      # 默认 build-artifacts/device.jpeg
set -u
export MSYS_NO_PATHCONV=1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/common.sh"

OUT="${1:-$OHOS_SHOT}"
REMOTE=/data/local/tmp/appcenter-snap.jpeg

require_device

hdc_run shell "power-shell wakeup" >/dev/null 2>&1 || true
hdc_run shell "uinput -T -m 540 2000 540 500 250" >/dev/null 2>&1 || true
sleep 1
hdc_run shell "snapshot_display -f $REMOTE" >/dev/null
hdc_run file recv "$REMOTE" "$(cygpath -w "$OUT")" >/dev/null
ok "shot: $OUT"
