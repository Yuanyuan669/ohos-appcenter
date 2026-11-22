#!/usr/bin/env bash
# Build a complete, self-consistent signing set for the store client.
#
#   OpenHarmony Application Root CA      (public test PKI shipped inside the SDK)
#     └── OpenHarmony Application CA     (private key is in OpenHarmony.p12)
#           └── App Center App           (issued here, valid 10 years)
#
# The SDK ships OpenHarmony.p12 with the *private keys* of that root and sub-CA,
# so an app can be certified by the chain a stock developer image already trusts
# -- no vendor certificate, no AppGallery account.
#
# Outputs (git-ignored; regenerate on CI or restore from secrets):
#   root-ca.cer / app-ca.cer     the two public CA certificates
#   appcenter.p12                our app key pair (alias appcenter-app-key-v1)
#   appcenter-app.cer            3-cert chain: leaf, sub-CA, root
#   appcenter-profile.json       profile carrying our bundle name, unsigned
#   appcenter-profile.p7b        that profile, signed by the Profile Release key
#
# Re-running is safe: everything is recreated from scratch.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

LIB="$OHOS_SDK_TOOLCHAINS/lib"
SIGN="$OHOS_SIGN_DIR"
JAR="$LIB/hap-sign-tool.jar"
SDK_P12="$LIB/OpenHarmony.p12"
SDK_PEM="$LIB/OpenHarmonyProfileRelease.pem"
SDK_PROF="$LIB/UnsgnedReleasedProfileTemplate.json"

BUNDLE="$OHOS_BUNDLE"
APP_ALIAS="$OHOS_KEY_ALIAS"
APP_PWD="$OHOS_KEY_PWD"
STORE_PWD="$OHOS_STORE_PWD"
CA_ALIAS="openharmony application ca"
PROFILE_ALIAS="openharmony application profile release"
P12_PWD="${OHOS_SDK_P12_PWD:-123456}"

for f in "$JAR" "$SDK_P12" "$SDK_PEM" "$SDK_PROF"; do
  [ -f "$f" ] || fail "缺 $f\n     先跑 ohos-kiosk/scripts/get-ohos-sdk.sh，或 export OHOS_SDK_TOOLCHAINS=<SDK>/toolchains"
done
"$JAVA_BIN" -version >/dev/null 2>&1 || fail "需要 JDK：$JAVA_BIN 不能执行"

sig() {
  "$JAVA_BIN" -jar "$JAR" "$@" 2>&1 |
    grep -vE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (DEBUG|TRACE)' |
    sed 's/^[0-9]{2}-.*INFO  - /    /'
}

mkdir -p "$SIGN"
cd "$SIGN"

step "1/5 导出 OpenHarmony 的两级 CA 证书"
# OpenHarmonyProfileRelease.pem = root CA, application CA, profile cert (in order)
awk 'BEGIN{n=0} /BEGIN CERT/{n++} n>0{print > (".c" n ".pem")}' "$SDK_PEM"
mv .c1.pem root-ca.cer
mv .c2.pem app-ca.cer
rm -f .c3.pem
openssl x509 -in root-ca.cer -noout -subject | sed 's/^/    /'
openssl x509 -in app-ca.cer -noout -subject | sed 's/^/    /'

step "2/5 生成应用密钥对 -> appcenter.p12"
# 默认复用已有密钥/证书：换 ACL、改 Profile 字段时不该换签名，
# 否则已装的商店会被判定为「签名不一致」，只能卸载重装（应用数据会丢）。
# 需要真正换密钥时设 OHOS_SIGN_FORCE=1。
if [ -f appcenter.p12 ] && [ -f appcenter-app.cer ] && [ -z "${OHOS_SIGN_FORCE:-}" ]; then
  ok "复用已有密钥与证书（OHOS_SIGN_FORCE=1 可强制重建）"
else
rm -f appcenter.p12
sig generate-keypair -keyAlias "$APP_ALIAS" -keyPwd "$APP_PWD" \
  -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile appcenter.p12 -keystorePwd "$STORE_PWD" \
  | grep -iE 'success|fail|error' || true

step "3/5 让 Application CA 给应用证书签名（10 年）"
rm -f appcenter-app.cer
sig generate-app-cert -keyAlias "$APP_ALIAS" -keyPwd "$APP_PWD" \
  -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
  -issuerKeyAlias "$CA_ALIAS" -issuerKeyPwd "$P12_PWD" \
  -subject "C=CN,O=OpenHarmony,OU=AppCenter,CN=App Center App" \
  -validity 3650 -signAlg SHA256withECDSA \
  -issuerKeystoreFile "$SDK_P12" -issuerKeystorePwd "$P12_PWD" \
  -keystoreFile appcenter.p12 -keystorePwd "$STORE_PWD" \
  -outForm certChain -rootCaCertFile root-ca.cer -subCaCertFile app-ca.cer \
  -outFile appcenter-app.cer \
  | grep -iE 'success|fail|error' || true
fi
[ -f appcenter-app.cer ] || fail "没有生成 appcenter-app.cer"
ok "chain 有 $(grep -c 'BEGIN CERT' appcenter-app.cer) 张证书（leaf -> sub-CA -> root）"

step "4/5 写 Profile：bundle-name=$BUNDLE  apl=${OHOS_APL:-system_core}"
# cert 1 of the chain is the leaf; the profile must name exactly that one.
awk 'BEGIN{n=0} /BEGIN CERT/{n++} n==1{print > "app-leaf.pem"}' appcenter-app.cer
"$OHOS_NODE" - "$SDK_PROF" "$BUNDLE" <<'NODE' || fail "node 生成 profile 失败"
const fs = require('fs');
const [src, bundle] = process.argv.slice(2);
const p = JSON.parse(fs.readFileSync(src, 'utf8'));
p['bundle-info']['bundle-name'] = bundle;
p['bundle-info']['distribution-certificate'] = fs.readFileSync('app-leaf.pem', 'utf8');
// apl / app-feature / ACL 决定这个包能不能静默安装别的应用。
// normal 只能入队等 PC agent；system_core 才拿得到 INSTALL_BUNDLE。
p['bundle-info']['apl'] = process.env.OHOS_APL || 'system_core';
p['bundle-info']['app-feature'] = process.env.OHOS_APP_FEATURE || 'hos_system_app';
const acls = (process.env.OHOS_ALLOWED_ACLS || '').split(/[, \t]+/).filter(Boolean);
p.acls = { 'allowed-acls': acls };
p['validity'] = { 'not-before': 1690000000, 'not-after': 2000000000 };
fs.writeFileSync('appcenter-profile.json', JSON.stringify(p, null, 4));
console.log('    bundle-name = ' + bundle +
  '  apl = ' + p['bundle-info']['apl'] +
  '  feature = ' + p['bundle-info']['app-feature'] +
  '  acls = [' + acls.join(', ') + ']');
console.log('    not-after = ' + new Date(p.validity['not-after'] * 1000).toISOString().slice(0, 10));
NODE

step "5/5 签名 Profile -> appcenter-profile.p7b"
rm -f appcenter-profile.p7b
sig sign-profile -mode localSign -keyAlias "$PROFILE_ALIAS" -keyPwd "$P12_PWD" \
  -profileCertFile "$SDK_PEM" -inFile appcenter-profile.json \
  -signAlg SHA256withECDSA -keystoreFile "$SDK_P12" -keystorePwd "$P12_PWD" \
  -outFile appcenter-profile.p7b \
  | grep -iE 'success|fail|error' || true

rm -f app-leaf.pem .c1.pem .c2.pem .c3.pem
echo
ok "签名材料齐了（$SIGN）"
echo "  keystore  $SIGN/appcenter.p12   alias=$APP_ALIAS  pwd=$APP_PWD"
echo "  cert      $SIGN/appcenter-app.cer"
echo "  profile   $SIGN/appcenter-profile.p7b"
echo "  SDK p12   $SDK_P12  (public OpenHarmony test PKI, store pwd $P12_PWD)"
echo
echo "接着：bash scripts/build.sh && bash scripts/sign.sh && bash scripts/deploy.sh"
