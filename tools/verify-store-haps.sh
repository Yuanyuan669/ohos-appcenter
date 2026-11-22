#!/usr/bin/env bash
# 发布前校验 store/ 里的每一个 HAP。
#
# 检查项：
#   1) HAP 签名链能被 hap-sign-tool verify-app 验证通过；
#   2) HAP 内嵌 Profile 的 bundle-name 与所在目录名一致；
#   3) 打印 signer / apl / app-feature / allowed-acls，便于审计。
#
# 用法：
#   bash tools/verify-store-haps.sh                # 默认 --store store
#   bash tools/verify-store-haps.sh --store <dir>
#
# 退出码非 0 表示有包不合格 —— 这种情况下不要发布索引。
#
# 背景：曾经出现过一个 HAP 的 Profile 写着别的 bundle-name（目录是
# com.local.browser，Profile 却是 com.local.transfer），设备端一律回
# 17700011「signature fails to be verified」，非常难猜。所以这个检查
# 必须进发布流程。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/env.sh"

STORE="$OHOS_PROJECT_ROOT/store"
while [ $# -gt 0 ]; do
  case "$1" in
    --store) STORE="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
STORE="$(cd "$STORE" && pwd)"

JAR="${HAP_SIGN_JAR:-$OHOS_SDK_TOOLCHAINS/lib/hap-sign-tool.jar}"
[ -f "$JAR" ] || { echo "找不到 hap-sign-tool.jar: $JAR" >&2; exit 1; }
[ -n "${OHOS_NODE:-}" ] || { echo "OHOS_NODE 未设置（scripts/env.sh 应已注入）" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILED=0
CHECKED=0

for dir in "$STORE"/apps/*/*/; do
  [ -d "$dir" ] || continue
  hap="$(ls "$dir"/*.hap 2>/dev/null | head -1)"
  [ -n "$hap" ] || continue
  CHECKED=$((CHECKED + 1))

  # 目录布局是 store/apps/<bundleName>/<versionCode>/，包名取两级 dirname。
  expect="$(basename "$(dirname "$dir")")"

  rm -f "$TMP/chain.cer" "$TMP/profile.p7b" "$TMP/profile.json" "$TMP/verify.log"
  "$JAVA_BIN" -jar "$JAR" verify-app -inFile "$hap" \
    -outCertChain "$TMP/chain.cer" -outProfile "$TMP/profile.p7b" >"$TMP/verify.log" 2>&1
  verified="$(grep -c 'verify: Verify success' "$TMP/verify.log" 2>/dev/null || true)"

  signer="?"
  if [ -s "$TMP/chain.cer" ]; then
    signer="$(awk 'BEGIN{n=0} /BEGIN CERT/{n++} n==1{print}' "$TMP/chain.cer" \
      | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
      | sed -e 's/subject=//' -e 's/.*CN=\([^,]*\).*/\1/')"
    [ -n "$signer" ] || signer="?"
  fi

  "$JAVA_BIN" -jar "$JAR" verify-profile -inFile "$TMP/profile.p7b" \
    -outFile "$TMP/profile.json" >/dev/null 2>&1
  fields="$("$OHOS_NODE" - "$TMP/profile.json" <<'NODE'
const fs = require('fs');
let p;
try {
  p = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).content;
} catch {
  console.log('?|?|?|?');
  process.exit(0);
}
const b = p['bundle-info'] || {};
const acls = ((p.acls || {})['allowed-acls'] || []).join(',');
console.log([b['bundle-name'] || '?', b['apl'] || '?', b['app-feature'] || '?', acls || '-'].join('|'));
NODE
)"
  IFS='|' read -r actual apl feature acls <<<"$fields"

  mark="OK  "
  if [ "$verified" -lt 1 ] || [ "$actual" != "$expect" ]; then
    mark="BAD "
    FAILED=$((FAILED + 1))
  fi

  printf '%s %-30s profile=%-30s apl=%-11s feature=%-15s acls=%-28s signer=%s\n' \
    "$mark" "$expect" "$actual" "$apl" "$feature" "$acls" "$signer"
  if [ "$actual" != "$expect" ]; then
    printf '       ^ Profile 包名与目录不一致（设备会报 17700011）\n'
  fi
  if [ "$verified" -lt 1 ]; then
    printf '       ^ 签名链验证失败：\n'
    sed 's/^/         /' "$TMP/verify.log" | tail -5
  fi
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "全部通过：$CHECKED 个 HAP"
  exit 0
fi
echo "有 $FAILED / $CHECKED 个 HAP 不合格 —— 修好再发布（见 docs/SIGNING.md）" >&2
exit 1
