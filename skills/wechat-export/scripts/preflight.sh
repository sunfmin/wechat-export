#!/bin/bash
# preflight.sh — read-only environment check for the WeChat export pipeline.
# No side effects: detects WeChat, the logged-in account dir, the encrypted DBs,
# and the toolchain. Run this first; it is also the pipeline's dry-run/sandbox mode.
#
# Usage: preflight.sh
# Exit 0 if the environment can support an export; non-zero (with reasons) otherwise.
set -uo pipefail

ok=0; warn=0; fail=0
say()  { printf '  %s %s\n' "$1" "$2"; }
pass() { say "✓" "$1"; ok=$((ok+1)); }
note() { say "•" "$1"; warn=$((warn+1)); }
bad()  { say "✗" "$1"; fail=$((fail+1)); }

echo "=== wechat-export preflight ==="

# 1. platform
[ "$(uname -s)" = "Darwin" ] && pass "macOS ($(sw_vers -productVersion 2>/dev/null))" \
  || bad "not macOS — this pipeline is macOS-only"
[ "$(uname -m)" = "arm64" ] && pass "Apple Silicon" || note "not arm64 (built/tested on arm64)"

# 2. WeChat app + version
APP=/Applications/WeChat.app
if [ -d "$APP" ]; then
  VER=$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)
  pass "WeChat.app present (v$VER)"
  case "$VER" in 4.*) pass "WeChat 4.x (SQLCipher-4 scheme)";; *) note "version $VER — pipeline verified on 4.x";; esac
  # Build provenance decides whether key extraction is even possible. Frida needs an ad-hoc
  # re-sign to attach; the App Store build (ships a _MASReceipt, team-bound sandbox
  # entitlements, no cs.allow) is REJECTED by AMFI after re-sign (Launchd spawn error 163)
  # — a hard dead end. The weixin.qq.com direct-download build carries
  # com.apple.security.cs.allow-* and re-signs + launches fine.
  if [ -e "$APP/Contents/_MASReceipt/receipt" ]; then
    bad "App Store 版 WeChat（含 _MASReceipt）：重签后会被 AMFI 拒绝启动（spawn error 163），无法抓钥。请改装官网直装版：https://mac.weixin.qq.com"
  elif codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.cs.allow"; then
    pass "direct-download build（带 cs.allow entitlements，可重签+启动）"
  else
    note "未见 cs.allow entitlements——若重签后微信起不来，多半是 App Store 版，请换官网直装版 https://mac.weixin.qq.com"
  fi
else
  bad "WeChat.app not found in /Applications"
fi

# 3. logged-in account dir + encrypted DBs
BASE="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
ACC=""
if [ -d "$BASE" ]; then
  # account dir = the one that holds db_storage (name like <wxid>_<hash>)
  ACC=$(find "$BASE" -maxdepth 2 -type d -name db_storage 2>/dev/null | head -1 | xargs -I{} dirname {})
  if [ -n "$ACC" ]; then
    pass "account dir: ${ACC/#$HOME/~}"
    NDB=$(find "$ACC/db_storage" -name '*.db' 2>/dev/null | wc -l | tr -d ' ')
    [ "$NDB" -gt 0 ] && pass "encrypted DBs: $NDB under db_storage" || bad "no .db files under db_storage"
    # quick SQLCipher sanity: first DB should NOT start with the plaintext SQLite magic
    FDB=$(find "$ACC/db_storage" -name '*.db' 2>/dev/null | head -1)
    if [ -n "$FDB" ] && [ "$(head -c 15 "$FDB" 2>/dev/null)" = "SQLite format 3" ]; then
      note "$(basename "$FDB") looks unencrypted (already decrypted?)"
    else
      pass "DBs are encrypted (SQLCipher)"
    fi
  else
    bad "no db_storage found under $BASE — is WeChat logged in on this Mac?"
  fi
else
  bad "WeChat container not found — WeChat for Mac never ran/logged in here"
fi

# 4. toolchain
command -v uv  >/dev/null && pass "uv present" || bad "uv missing (needed to run Python/frida)"
command -v git >/dev/null && pass "git present" || bad "git missing (needed to clone tools)"
command -v codesign >/dev/null && pass "codesign present" || bad "codesign missing (Xcode CLT)"
command -v sudo >/dev/null && pass "sudo present (root needed for Frida)" || bad "sudo missing"
[ -d "/Applications/Google Chrome.app" ] && pass "Chrome present (optional, for PDF)" \
  || note "Chrome absent — HTML works without it; only a PDF export would need it"

echo "---"
echo "ok=$ok  notes=$warn  blockers=$fail"
if [ "$fail" -gt 0 ]; then
  echo "RESULT: BLOCKED — resolve the ✗ items above before exporting."
  exit 1
fi
echo "RESULT: READY"
[ -n "$ACC" ] && echo "ACCOUNT_DIR=$ACC"
exit 0
