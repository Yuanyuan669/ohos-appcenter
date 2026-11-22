#!/usr/bin/env bash
# 把商店地址预置到 appcenter 沙箱，并重启应用（设备侧调试/批量部署用）。
#   bash tools/dev-set-prefs.sh                       # 用默认 LAN 地址
#   bash tools/dev-set-prefs.sh http://1.2.3.4:8787/index.json [pin]
#
# 机制：应用启动时 preferences 为空 -> 读 <filesDir>/appcenter/index-url.txt
# （第一行 URL，第二行可选 PIN），读到后写回 preferences。见 SettingsStore.loadEffective。
set -u
HDC=/d/ohos-tools/sdk/openharmony/toolchains/hdc.exe
T=${OHOS_TARGET:-000000000000000000000000121601ad}
FILES=/data/app/el2/100/base/com.local.appcenter/haps/entry/files
URL="${1:-http://192.168.31.100:8787/index.json}"
PIN="${2:-}"
SHOT="${3:-/d/ohos/ohos-appcenter/build-artifacts/store-preflight.jpeg}"
LOCAL=/d/ohos-tools/index-url.txt
export MSYS_NO_PATHCONV=1

printf '%s\n%s\n' "$URL" "$PIN" > "$LOCAL"

"$HDC" -t "$T" shell "kill -9 \$(pidof com.local.appcenter)" 2>/dev/null || true
sleep 1
# 沙箱 uid 由系统在安装时分配（重装后会变），不要硬编码：读 files/ 的属主。
OWNER=$("$HDC" -t "$T" shell "ls -ld $FILES" | tr -d '\r' | awk '{print $3}')
[ -n "$OWNER" ] || { echo "无法读取 $FILES 的属主" >&2; exit 1; }
echo "sandbox owner: $OWNER"
"$HDC" -t "$T" shell "mkdir -p $FILES/appcenter"
# 清掉之前误写的 preferences 文件，避免和预置文件互相干扰
"$HDC" -t "$T" shell "rm -f /data/app/el2/100/base/com.local.appcenter/haps/entry/preferences/appcenter_settings.xml"
"$HDC" -t "$T" file send "$(cygpath -w "$LOCAL")" "$FILES/appcenter/index-url.txt"
"$HDC" -t "$T" shell "chown -R $OWNER:$OWNER $FILES/appcenter; chmod 770 $FILES/appcenter; chmod 660 $FILES/appcenter/index-url.txt"
"$HDC" -t "$T" shell "aa start -a EntryAbility -b com.local.appcenter"
sleep 5
"$HDC" -t "$T" shell "snapshot_display -f /data/local/tmp/preflight.jpeg"
"$HDC" -t "$T" file recv /data/local/tmp/preflight.jpeg "$(cygpath -w "$SHOT")"
echo "url:  $URL"
echo "shot: $SHOT"
