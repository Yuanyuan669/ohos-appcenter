#!/usr/bin/env bash
# Shared configuration for the store client build/sign/deploy chain.
#
# Machine-specific paths belong in scripts/env.local.sh (git-ignored), which is
# sourced first and wins over every default here.
ENV_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OHOS_PROJECT_ROOT="$(cd "$ENV_SH_DIR/.." && pwd)"

[ -f "$ENV_SH_DIR/env.local.sh" ] && . "$ENV_SH_DIR/env.local.sh"

# --- Project identity -------------------------------------------------------
export OHOS_BUNDLE="${OHOS_BUNDLE:-com.local.appcenter}"
export OHOS_ABILITY="${OHOS_ABILITY:-EntryAbility}"
export OHOS_MODULE="${OHOS_MODULE:-entry}"
export OHOS_PRODUCT="${OHOS_PRODUCT:-default}"
export OHOS_BUILD_MODE="${OHOS_BUILD_MODE:-debug}"
# hvigor project root. The store client keeps its app module in app/ so the
# repo root stays usable for the Node tooling.
export OHOS_APP_DIR="${OHOS_APP_DIR:-$OHOS_PROJECT_ROOT/app}"

# --- Device targeting -------------------------------------------------------
# A USB serial from `hdc list targets`, or IP:PORT for LAN deploys.
# Empty means: use whatever single device hdc reports.
export OHOS_TARGET="${OHOS_TARGET:-}"

# --- Toolchain discovery ----------------------------------------------------
# Root installed by ohos-kiosk/scripts/get-ohos-sdk.sh (OpenHarmony 4.0 / API 10).
OHOS_TOOLS_ROOT="${OHOS_TOOLS_ROOT:-${OHOS_TOOLS:-/d/ohos-tools}}"
export OHOS_BASE_SDK_HOME="${OHOS_BASE_SDK_HOME:-$OHOS_TOOLS_ROOT/sdk}"
export OHOS_SDK_TOOLCHAINS="${OHOS_SDK_TOOLCHAINS:-$OHOS_BASE_SDK_HOME/openharmony/toolchains}"
export HVIGOR_CLI="${HVIGOR_CLI:-$OHOS_TOOLS_ROOT/hvigor-3.2.4/node_modules/@ohos/hvigor/bin/hvigor-simple.js}"
# hvigorfile.ts does a bare `require('@ohos/hvigor-ohos-plugin')`, so the plugin
# has to be reachable through NODE_PATH.
export NODE_PATH="${NODE_PATH:-$OHOS_TOOLS_ROOT/hvigor-3.2.4/node_modules}"
export HVIGOR_USER_HOME="${HVIGOR_USER_HOME:-$OHOS_TOOLS_ROOT/hvigor-home}"
export DEVECO_HOME="${DEVECO_HOME:-/d/DevEcoStudio}"
export OHOS_NODE="${OHOS_NODE:-$DEVECO_HOME/tools/node/node.exe}"

# Prefer an explicit JDK 17 over DevEco's bundled Java 25: hap-sign-tool was
# verified against 17, and hvigor spawns a bare `java`.
for _jh in "${JAVA_HOME:-}" "$OHOS_TOOLS_ROOT/java/jdk-17"; do
  if [ -n "$_jh" ] && [ -x "$_jh/bin/java.exe" ]; then
    export JAVA_HOME="${_jh//\\//}"
    case ":$PATH:" in
      *":$JAVA_HOME/bin:"*) ;;
      *) export PATH="$JAVA_HOME/bin:$PATH" ;;
    esac
    break
  fi
done
if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java.exe" ]; then
  export JAVA_BIN="${JAVA_BIN:-${JAVA_HOME}/bin/java.exe}"
else
  export JAVA_BIN="${JAVA_BIN:-java}"
fi

# --- Signing materials ------------------------------------------------------
export OHOS_SIGN_DIR="${OHOS_SIGN_DIR:-$OHOS_PROJECT_ROOT/signing}"
export OHOS_KEY_ALIAS="${OHOS_KEY_ALIAS:-appcenter-app-key-v1}"
export OHOS_KEYSTORE="${OHOS_KEYSTORE:-$OHOS_SIGN_DIR/appcenter.p12}"
export OHOS_APP_CERT="${OHOS_APP_CERT:-$OHOS_SIGN_DIR/appcenter-app.cer}"
export OHOS_PROFILE="${OHOS_PROFILE:-$OHOS_SIGN_DIR/appcenter-profile.p7b}"
# Passwords belong in a secret store on CI, never in git.
export OHOS_STORE_PWD="${OHOS_STORE_PWD:-123456}"
export OHOS_KEY_PWD="${OHOS_KEY_PWD:-123456}"

# --- Privilege (profile fields) ---------------------------------------------
# The store installs HAPs on-device, which needs ohos.permission.INSTALL_BUNDLE
# (availableLevel = system_core). A normal-APL profile can never be granted it,
# so the store itself is signed as a system app; the OpenHarmony test PKI ships
# the keys, and the device accepts it (verified on 4.1.7.5).
#
# OHOS_APL=normal builds the fallback variant: install attempts return 201 and
# the app hands downloaded HAPs to agent/pc-agent.mjs instead.
export OHOS_APL="${OHOS_APL:-system_core}"
export OHOS_APP_FEATURE="${OHOS_APP_FEATURE:-hos_system_app}"
export OHOS_ALLOWED_ACLS="${OHOS_ALLOWED_ACLS:-ohos.permission.INSTALL_BUNDLE}"

# --- Output -----------------------------------------------------------------
export OHOS_OUT_DIR="${OHOS_OUT_DIR:-$OHOS_PROJECT_ROOT/build-artifacts}"
export OHOS_UNSIGNED_HAP="${OHOS_UNSIGNED_HAP:-$OHOS_OUT_DIR/entry-unsigned.hap}"
export OHOS_SIGNED_HAP="${OHOS_SIGNED_HAP:-$OHOS_OUT_DIR/entry-signed.hap}"
export OHOS_SHOT="${OHOS_SHOT:-$OHOS_OUT_DIR/device.jpeg}"
