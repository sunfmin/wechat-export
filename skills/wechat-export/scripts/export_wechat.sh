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

# ── 3. re-sign WeChat with get-task-allow (ad-hoc) so Frida can attach ───────
step 3 "re-sign WeChat (get-task-allow)"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "  已带 get-task-allow，跳过"
else
  cat > "$WORK/ent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
  codesign -f -s - --deep --entitlements "$WORK/ent.plist" "$APP" || die "re-sign failed"
  echo "  ✓ re-signed"
fi

# ── 4. extract keys via Frida CCCrypt hook (NEEDS ROOT + you triggering) ─────
step 4 "extract keys (Frida CCCrypt)"
if [ -s "$KEYS" ]; then echo "  keys.json 已存在，跳过"; else
  pkill -x WeChat 2>/dev/null; sleep 1; open -a "$APP"; sleep 3
  cat <<EOF

  >>> 手动步骤 (A)+(B) <<<
  接下来会用 sudo 以 root 运行 Frida 抓密钥（会弹密码/askpass）。
  抓取窗口内，请在微信里【打开和「$PERSON」的聊天】，并点一下 收藏/搜索、上下滚动，
  触发数据库解密。最多等 ${WKM_WAIT:-200} 秒。
EOF
  sudo "$PY" "$WKM/scripts/extract_key.py" --db-dir "$ACC/db_storage" \
       --output "$KEYS" --wait "${WKM_WAIT:-200}" || die "key extraction failed"
  [ -s "$KEYS" ] || die "no keys captured — 重跑本脚本会从这一步继续（记得触发解密）"
  sudo chown "$(id -un)" "$KEYS"; chmod 600 "$KEYS"
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
pkill -x WeChat 2>/dev/null; sleep 1
codesign -f -s - --deep "$APP" && echo "  ✓ get-task-allow 已移除（如仍打不开，重装微信最干净；数据不受影响）"

printf '\n\033[32m✓ 完成：%s\033[0m\n' "$OUT"
echo "  备份：$WORK/db-backup    中间产物：$WORK（确认无误后可删）"
