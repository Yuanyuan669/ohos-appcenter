#!/usr/bin/env bash
# Sign the store client HAP with hap-sign-tool: no IDE, no network, just JDK.
#   bash scripts/sign.sh
#
# Materials created by scripts/make-signing-material.sh:
#   signing/appcenter.p12        app key pair, alias appcenter-app-key-v1
#   signing/appcenter-app.cer    3-cert chain ending in that key's certificate
#   signing/appcenter-profile.p7b profile whose bundle-name == $OHOS_BUNDLE
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [ -f "$OHOS_SIGNED_HAP" ] && [ ! -f "$OHOS_UNSIGNED_HAP" ]; then
  step "已有签名包"; ok "$OHOS_SIGNED_HAP"; exit 0
fi
[ -f "$OHOS_UNSIGNED_HAP" ] || fail "找不到 $OHOS_UNSIGNED_HAP，先跑 build.sh"

step "定位签名工具"
JAR="${HAP_SIGN_JAR:-$OHOS_SDK_TOOLCHAINS/lib/hap-sign-tool.jar}"
[ -f "$JAR" ] || fail "hap-sign-tool.jar 未找到：$JAR"
ok "$JAR"
"$JAVA_BIN" -version >/dev/null 2>&1 || fail "需要可执行的 JDK：$JAVA_BIN"
ok "java: $("$JAVA_BIN" -version 2>&1 | head -1)"

step "定位签名材料"
require_signing
ok "keystore=$OHOS_KEYSTORE"
ok "cert=$OHOS_APP_CERT"
ok "profile=$OHOS_PROFILE"
[ "$(basename "$OHOS_KEYSTORE")" = "OpenHarmony.p12" ] \
  && warn "用的是 SDK 自带 OpenHarmony.p12，应换成 signing/appcenter.p12"

step "sign-app"
rm -f "$OHOS_SIGNED_HAP"
"$JAVA_BIN" -jar "$JAR" sign-app \
  -mode localSign \
  -signAlg SHA256withECDSA \
  -keystoreFile "$OHOS_KEYSTORE" \
  -keystorePwd "$OHOS_STORE_PWD" \
  -keyAlias "$OHOS_KEY_ALIAS" \
  -keyPwd "$OHOS_KEY_PWD" \
  -appCertFile "$OHOS_APP_CERT" \
  -profileFile "$OHOS_PROFILE" \
  -inFile "$OHOS_UNSIGNED_HAP" \
  -outFile "$OHOS_SIGNED_HAP" \
  || fail "签名失败。排查：
     'Signature did not verify' -> .cer 的叶证书与 -keyAlias 的公钥不是同一对
     'certificate in profile' -> Profile 的 distribution-certificate 与 -appCertFile 不一致
     'profile 打不开'         -> .p7b 不是本 SDK 签的，重跑 make-signing-material.sh"
[ -s "$OHOS_SIGNED_HAP" ] || fail "签名产物为空"
ok "signed -> $OHOS_SIGNED_HAP ($(wc -c < "$OHOS_SIGNED_HAP") bytes)"

step "verify-app 自检"
"$JAVA_BIN" -jar "$JAR" verify-app -inFile "$OHOS_SIGNED_HAP" \
  -outCertChain "$OHOS_OUT_DIR/verify-chain.cer" -outProfile "$OHOS_OUT_DIR/verify-profile.p7b" \
  | grep -E 'verify: |Digest verify|Signature Algorithm' | sed 's/^.*INFO  - /    /'
rm -f "$OHOS_OUT_DIR/verify-chain.cer" "$OHOS_OUT_DIR/verify-profile.p7b"
