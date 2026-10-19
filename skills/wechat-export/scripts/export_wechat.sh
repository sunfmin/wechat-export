#!/bin/bash
# export_wechat.sh — assisted, idempotent pipeline to export ONE WeChat contact's full
# history (macOS WeChat 4.x) to a single self-contained HTML.
#
#   export_wechat.sh "<person>"      person = 备注名 / 昵称 / 微信号(alias) / wxid
#
# Env knobs:
#   WORK   work dir (default: ./wechat-export-work)
#   OUT    output HTML (default: ~/Desktop/微信聊天记录-<person>-<span>.html)
#
# Design: every phase is idempotent — it skips when its artifact already exists, so a
# re-run RESUMES. Two phases need a human and the script stops with instructions:
#   (A) sudo password for root (Frida needs task_for_pid)
#   (B) triggering decryption — you open the target chat in WeChat and tap 收藏/搜索/scroll
#       so page reads fire CCCrypt and the key is captured.
# It operates read-only on the databases (copies them out), backs up db_storage first,
# and restores WeChat's signature (removes get-task-allow) at the end.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PERSON="${1:-}"
[ -z "$PERSON" ] && { echo "usage: export_wechat.sh \"<备注名/昵称/微信号/wxid>\""; exit 2; }

WORK="${WORK:-$PWD/wechat-export-work}"
APP=/Applications/WeChat.app
WKM="$WORK/wechat-key-macos"
WXBAK="$WORK/wechat4-db-export"
VENV="$WORK/venv"
KEYS="$WORK/keys.json"
mkdir -p "$WORK"

# How to gain root for Frida. Default is plain `sudo` (interactive tty). On a headless /
# no-tty host, use sudo's askpass: export SUDO_ASKPASS and set SUDO to "sudo -A", e.g.:
#   SUDO_ASKPASS="$HOME/.local/bin/askpass" SUDO="sudo -A" scripts/export_wechat.sh "<who>"
# SUDO is intentionally word-split (so "sudo -A" works); keep paths in it space-free.
SUDO="${SUDO:-sudo}"

step() { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$1"; exit 1; }

# ── 0. preflight ────────────────────────────────────────────────────────────
step 0 "preflight"
PF=$(bash "$HERE/preflight.sh") || { echo "$PF"; die "preflight blocked — fix the ✗ items"; }
echo "$PF" | tail -4
ACC=$(echo "$PF" | sed -n 's/^ACCOUNT_DIR=//p'); [ -n "$ACC" ] || die "no account dir"
ACCNAME="$(basename "$ACC")"

# ── 1. backup encrypted db_storage (safety; idempotent) ─────────────────────
step 1 "backup db_storage"
if [ -d "$WORK/db-backup" ]; then echo "  已存在，跳过"; else
  cp -a "$ACC/db_storage" "$WORK/db-backup" && echo "  → $WORK/db-backup"
fi

# ── 2. fetch tools + python env (frida<17, pycryptodome, zstandard) ─────────
step 2 "tools + venv"
[ -d "$WKM" ]   || git clone --depth 1 https://github.com/3351666087/wechat-key-macos "$WKM"
[ -d "$WXBAK" ] || git clone --depth 1 https://github.com/Z-V-I/wechat4-db-export "$WXBAK"
if [ ! -d "$VENV" ]; then
  uv venv "$VENV" >/dev/null
  uv pip install --python "$VENV/bin/python" 'frida<17' pycryptodome zstandard >/dev/null
fi
PY="$VENV/bin/python"
echo "  frida $("$PY" -c 'import frida;print(frida.__version__)' 2>/dev/null)"

# ── 2.5 reuse a previously-captured key → skip the whole re-sign + Frida dance ─
# The DB key is tied to your account + the existing db files, not to the WeChat binary,
# so a key captured once stays valid until WeChat re-initialises its databases (i.e. you
# log out and back in). If you already have it, the export needs NO sudo, NO re-sign, NO
# Frida and NO manual trigger — it just decrypts. Supply the key either as $WORK/keys.json
# or compact in the WECHAT_KEYS_JSON env var (e.g. from your own secret store). Portable
# and self-contained; this script never reaches into any particular keychain/manager.
if [ ! -s "$KEYS" ] && [ -n "${WECHAT_KEYS_JSON:-}" ]; then
  printf '%s' "$WECHAT_KEYS_JSON" > "$KEYS" && chmod 600 "$KEYS"
fi
HAVE_KEYS=0; [ -s "$KEYS" ] && HAVE_KEYS=1

# ── 3. re-sign WeChat with get-task-allow (ad-hoc) so Frida can attach ───────
# CRITICAL: preserve WeChat's ORIGINAL entitlements and only ADD get-task-allow.
# Signing with get-task-allow alone strips the sandbox/keychain entitlements the app
# needs, and a 4.x build then silently fails to launch (open succeeds, process dies).
step 3 "re-sign WeChat (preserve entitlements + get-task-allow)"
if [ "$HAVE_KEYS" = 1 ]; then
  echo "  已有密钥（keys.json / WECHAT_KEYS_JSON），无需重签或抓钥，跳过"
elif codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "  已带 get-task-allow，跳过"
else
  ENTS="$WORK/wechat-entitlements.plist"
  # dump the genuine entitlements (strip any pre-XML blob header from older codesign)
  codesign -d --entitlements :- "$APP" 2>/dev/null > "$ENTS.raw"
  if grep -q "<?xml" "$ENTS.raw"; then
    sed -n '/<?xml/,$p' "$ENTS.raw" > "$ENTS"
  else
    # no entitlements to preserve → minimal plist
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict></dict></plist>' > "$ENTS"
  fi
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$ENTS" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :com.apple.security.get-task-allow true" "$ENTS"
  echo "  entitlements: $(grep -c '<key>' "$ENTS") 项（含 get-task-allow）"
  # app may be root-owned (after a fresh reinstall) → fall back to sudo
  codesign -f -s - --deep --entitlements "$ENTS" "$APP" 2>/dev/null \
    || $SUDO codesign -f -s - --deep --entitlements "$ENTS" "$APP" \
    || die "re-sign failed"
  echo "  ✓ re-signed（保留原 entitlements）"
fi

# ── 4. extract keys via Frida CCCrypt hook (NEEDS ROOT + you triggering) ─────
step 4 "extract keys (Frida CCCrypt)"
if [ -s "$KEYS" ]; then echo "  keys.json 已存在，跳过"; else
  pkill -x WeChat 2>/dev/null; sleep 1; open -a "$APP" 2>/dev/null
  # re-signed WeChat must actually be RUNNING for Frida to attach; wait up to 20s
  for _ in $(seq 1 20); do pgrep -x WeChat >/dev/null && break; sleep 1; done
  pgrep -x WeChat >/dev/null \
    || die "re-signed WeChat 未能启动（通常是 entitlements 没保全）。本脚本已保全原 entitlements；若仍失败，请重装微信后重跑"
  cat <<'EOF'

  >>> 手动步骤 (A)+(B) <<<
  接下来会用 sudo 以 root 运行 Frida 抓密钥（会弹密码/askpass）。
  抓取窗口内，请在微信里打开目标会话，并点一下 收藏/搜索、上下滚动，触发数据库解密。
EOF
  printf '  目标会话：%s （最多等 %s 秒）\n\n' "$PERSON" "${WKM_WAIT:-200}"
  $SUDO "$PY" "$WKM/scripts/extract_key.py" --db-dir "$ACC/db_storage" \
       --output "$KEYS" --wait "${WKM_WAIT:-200}" || die "key extraction failed"
  [ -s "$KEYS" ] || die "no keys captured — 重跑本脚本会从这一步继续（记得触发解密）"
  $SUDO chown "$(id -un)" "$KEYS"; chmod 600 "$KEYS"
  echo "  ✓ keys → $KEYS"
fi

# ── 5. decrypt (incl WAL) with wxbak, using captured keys ───────────────────
step 5 "decrypt (wxbak refresh)"
export WXBAK_HOME="$WORK/wxbak-home"
mkdir -p "$WXBAK_HOME/keys"
cp "$KEYS" "$WXBAK_HOME/keys/$ACCNAME.json"
DECR="$WXBAK_HOME/work/$ACCNAME"
if [ -d "$DECR/message" ]; then echo "  已解密，跳过"; else
  "$PY" "$WXBAK/scripts/wxbak.py" --data-dir "$ACC" refresh || echo "  (refresh 末尾可能有无害报错，继续)"
fi

# ── 6. export the one conversation to JSON ──────────────────────────────────
step 6 "export conversation → JSON"
EXP="$WORK/export"; mkdir -p "$EXP"
"$PY" "$WXBAK/scripts/wxbak.py" --data-dir "$ACC" export --who "$PERSON" --format json --out "$EXP" \
  || die "export failed — 用 'wxbak.py --data-dir $ACC list' 确认 <$PERSON> 的名字/微信号"
JSON=$(ls -t "$EXP"/*.json 2>/dev/null | head -1)
[ -n "$JSON" ] || die "no JSON produced — person 名字可能不对，先跑 list"
echo "  → $JSON"

# ── 7. render single-file HTML ──────────────────────────────────────────────
step 7 "render HTML"
SPAN=$("$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));m=d['messages'];print((m[0]['time'][:10]+'_'+m[-1]['time'][:10]) if m else 'empty')" "$JSON")
OUT="${OUT:-$HOME/Desktop/微信聊天记录-${PERSON}-${SPAN}.html}"
"$PY" "$HERE/render_html.py" "$JSON" "$OUT" || die "render failed"

# ── 8. restore WeChat signature (remove get-task-allow) ─────────────────────
step 8 "restore WeChat signature"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q get-task-allow; then
  pkill -x WeChat 2>/dev/null; sleep 1
  # Remove ONLY get-task-allow, KEEP the rest of the entitlements. Re-signing with no
  # --entitlements would strip sandbox / keychain / cs.allow too and leave WeChat unable to
  # launch — the very failure this pipeline works around. True Tencent signature can't be
  # restored by us (ad-hoc now); a reinstall is the only genuine fix, data untouched.
  ENTS8="$WORK/wechat-entitlements-restore.plist"
  codesign -d --entitlements :- "$APP" 2>/dev/null | sed -n '/<?xml/,$p' > "$ENTS8"
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENTS8" 2>/dev/null || true
  { codesign -f -s - --deep --entitlements "$ENTS8" "$APP" 2>/dev/null \
      || $SUDO codesign -f -s - --deep --entitlements "$ENTS8" "$APP"; } \
    && echo "  ✓ get-task-allow 已移除、其余 entitlements 保留（彻底复原仍以重装最干净，数据不受影响）"
else
  echo "  签名未被改动（用的是已有密钥，没重签），跳过"
fi

printf '\n\033[32m✓ 完成：%s\033[0m\n' "$OUT"
echo "  备份：${WORK}/db-backup    中间产物：${WORK}（确认无误后可删）"
