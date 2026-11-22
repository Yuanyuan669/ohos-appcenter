#!/usr/bin/env bash
# Small shared helpers: colored steps, device plumbing, signing discovery.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

if [ -t 1 ]; then
  C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
  C_STEP=$'\033[1;36m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_STEP=''; C_OFF=''
fi

step() { echo; echo "${C_STEP}==> $*${C_OFF}"; }
ok()   { echo "${C_OK}[ ok ]${C_OFF} $*"; }
warn() { echo "${C_WARN}[warn]${C_OFF} $*"; }
fail() { echo "${C_ERR}[fail]${C_OFF} $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

resolve_node() {
  if [ -n "${OHOS_NODE:-}" ] && [ -x "$OHOS_NODE" ]; then echo "$OHOS_NODE"; return 0; fi
  need node && { echo node; return 0; }
  return 1
}

find_hdc() {
  if [ -n "${HDC:-}" ] && [ -x "$HDC" ]; then echo "$HDC"; return 0; fi
  for c in "$OHOS_SDK_TOOLCHAINS/hdc.exe" "$OHOS_SDK_TOOLCHAINS/hdc" \
           "$OHOS_BASE_SDK_HOME/openharmony/toolchains/hdc.exe"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  need hdc && { command -v hdc; return 0; }
  return 1
}

HDC_BIN="${HDC:-$(find_hdc || true)}"

hdc_run() {
  [ -n "$HDC_BIN" ] || fail "找不到 hdc。装好 SDK 或 export HDC=<hdc 路径>"
  if [ -n "$OHOS_TARGET" ]; then
    "$HDC_BIN" -t "$OHOS_TARGET" "$@"
  else
    "$HDC_BIN" "$@"
  fi
}

require_device() {
  [ -n "$HDC_BIN" ] || fail "找不到 hdc（$OHOS_SDK_TOOLCHAINS/hdc.exe）"
  local targets
  targets="$(hdc_run list targets 2>/dev/null | tr -d '\r' | grep -v '[Empty]' || true)"
  if [ -z "$OHOS_TARGET" ]; then
    [ -n "$targets" ] || fail "没有检测到设备。插 USB 或 export OHOS_TARGET=<serial|IP:PORT>"
    echo "$targets" | head -1 | grep -qx . && OHOS_TARGET="$(echo "$targets" | head -1)"
    ok "device: $OHOS_TARGET"
  else
    echo "$targets" | grep -qx "$OHOS_TARGET" \
      || fail "设备 $OHOS_TARGET 不在 hdc 列表里（当前：$(echo "$targets" | tr '\n' ' ')）"
    ok "device: $OHOS_TARGET"
  fi
}

require_signing() {
  for f in "$OHOS_KEYSTORE" "$OHOS_APP_CERT" "$OHOS_PROFILE"; do
    [ -f "$f" ] || fail "缺签名材料 $f。先跑 bash scripts/make-signing-material.sh"
  done
}
