---
name: wechat-export
description: >-
  Export ONE WeChat contact's complete chat history on macOS (WeChat for Mac 4.x) into a
  single self-contained, mobile-friendly HTML file — WeChat-style bubbles, built-in
  emoticons mapped to system emoji, quote replies as grey quote boxes, every asset inlined,
  zero external dependencies. Use when the user wants to export, back up, archive, or save
  one person's full WeChat conversation from the Mac app to a single file (HTML, or PDF via
  the browser) and explicitly does NOT want a whole-phone iPhone backup. Triggers on
  "导出微信聊天记录", "把和某人的微信聊天记录从头到尾导出成 HTML/PDF", "微信 Mac 版某个联系人聊天
  记录存档/备份", "export my WeChat chat with <person> to a single file", "self-contained HTML
  of one WeChat conversation". NOT for sending WeChat messages, WeChat Mini-Program
  development, recovering deleted messages, or exporting Slack/Jira (that is mywork).
---

# wechat-export — one WeChat conversation → one HTML file

Exports a single contact's **entire** history from **WeChat for Mac 4.x** to a self-contained
HTML (WeChat-style bubbles, emoji, quote boxes). No whole-phone backup, no external assets.

**Authorization:** only for the user exporting **their own** WeChat data on **their own** Mac.
It extracts the local database key by running a re-signed **copy** of WeChat under Frida — the
installed `/Applications/WeChat.app` is never modified. Do not use it against an account or a
machine that is not the user's.

## What it takes
- macOS, Apple Silicon, **WeChat for Mac 4.x logged in** on this machine.
- The **direct-download build** from https://mac.weixin.qq.com — **not** the Mac App Store
  build. Key extraction needs an ad-hoc re-sign to let Frida attach; the App Store build
  (ships a `_MASReceipt`, team-bound sandbox entitlements, no `cs.allow`) is rejected by AMFI
  after re-sign (`Launchd job spawn failed, error=163`) — a hard dead end. `preflight.sh`
  detects this and blocks. The direct-download build carries `com.apple.security.cs.allow-*`
  and re-signs + launches fine.
- **root** (sudo) — Frida needs `task_for_pid`. Plus ~1.4 GB of free disk for the WeChat copy
  (an APFS clone, so near-instant and near-zero real bytes).
- `uv`, `git`, Xcode CLT (`codesign`). The pipeline installs `frida<17`, `pycryptodome`,
  `zstandard` into its own venv. Chrome only if the user also wants a PDF.
- Two tools cloned on demand: `3351666087/wechat-key-macos` (Frida key hook) and
  `Z-V-I/wechat4-db-export` (decrypt + export).

## Two unavoidable manual moments (first capture only)
The rest is automated, but the **first** key capture needs a human — tell the user up front:
1. **sudo password** when Frida starts as root.
2. **Trigger decryption** — the user opens the target chat in WeChat and taps 收藏/搜索 and
   scrolls, so page reads fire `CCCrypt` and the key is captured. Nothing to capture if WeChat
   just sits idle.

**Both are skipped once you have the key.** The DB key is tied to the account + the existing
database files, not to the WeChat binary, so a key captured once stays valid until WeChat
re-initialises its databases (i.e. the user logs out and back in). Supply a saved key and the
export needs no sudo, no re-sign, no Frida and no trigger — it just decrypts (see step 2).

## Do this

**1 — Preflight (always).** Confirm the environment and find the account dir:
```bash
bash scripts/preflight.sh
```
Blockers print as ✗. On READY it prints `ACCOUNT_DIR=…`. This is also the safe dry-run.

**2 — Run the pipeline.** One command, idempotent (re-run to resume — each phase skips when its
artifact exists):
```bash
scripts/export_wechat.sh "<备注名/昵称/微信号/wxid>"
```
It backs up `db_storage`, clones the tools, makes a re-signed **copy** of WeChat (with
`get-task-allow`; `/Applications` is left untouched), runs that copy and captures the key via
Frida (← manual moments 1 & 2 happen here), decrypts with wxbak (incl. WAL), exports the one
conversation to JSON, renders the HTML to `~/Desktop/微信聊天记录-<person>-<span>.html`, and
relaunches the genuine app. Env knobs: `WORK=<dir>`, `OUT=<file.html>`, `WKM_WAIT=<seconds>`.

**Reuse a saved key (skip the copy + Frida).** If you captured the key on a past run, supply it
and phases 3–4 (the WeChat copy + Frida + both manual moments) are skipped — fully automatic,
read-only, WeChat not even launched. Either drop the key at `$WORK/keys.json`, or pass it compact
via env:
```bash
WECHAT_KEYS_JSON='{"message/message_0.db":{"enc_key":"…","salt":"…"},…}' scripts/export_wechat.sh "<who>"
```
Feed it from wherever you keep secrets, e.g. `WECHAT_KEYS_JSON="$(your-secret-tool get …)"`. The
key stays valid until WeChat re-initialises its DBs (logout→login); keep the `db-backup/` and that
key together for a permanently re-decryptable snapshot.

On a **headless / no-tty host** plain `sudo` can't prompt — use sudo's askpass:
```bash
SUDO_ASKPASS="$HOME/.local/bin/askpass" SUDO="sudo -A" scripts/export_wechat.sh "<who>"
```
(A GUI password dialog pops for approval. Also works for a **group chat** — pass the group's
name as `<who>`; each sender shows on the left with their name, me on the right.)

**If the person name doesn't resolve**, list conversations and pick the exact 备注/昵称/微信号:
```bash
WORK=./wechat-export-work
"$WORK/venv/bin/python" "$WORK/wechat4-db-export/scripts/wxbak.py" \
  --data-dir "<ACCOUNT_DIR>" list
```
(备注名/昵称/微信号 all work as `--who`; 微信号 is `alias`, distinct from the internal `username`.)

**3 — PDF (only if asked).** The HTML already carries an `@media print` block:
```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu \
  --no-pdf-header-footer --print-to-pdf="<out.pdf>" "file://<out.html>"
```

## Verify before declaring done
```bash
python3 scripts/selftest.py            # renderer self-check on the bundled fixture
```
For a real export, open the HTML and confirm: bubbles on the right (me) / left (other), date
dividers, emoji rendered (not literal `[拥抱]`), quote boxes present, and `scrollWidth <=
innerWidth` at phone width (no horizontal scroll).

## Cleanup (do it, and tell the user)
- The installed `/Applications/WeChat.app` is **never modified** — Frida runs against a copy —
  so there is no signature to restore. The genuine app keeps working throughout.
- The `WORK` dir holds a full `db-backup/`, the 1.4 GB re-signed `WeChat-crack.app` copy, and
  other intermediates — all safe to delete once the HTML checks out. Say where it is; don't
  delete without the user's ok.

## Known limitations (state them, don't hide them)
- **Media are text placeholders** (`[图片]`/`[视频]`/`[语音]`). Real images aren't embedded:
  the thumbnail `.dat` is AES-encrypted (format "V2", header `07 08 56 32`) and the image key
  is a separate capture, not yet implemented. Text, transfers, quotes, system notices are
  complete.
- Verified on **4.1.13** and **4.1.15** (direct-download). Other 4.x builds may shift
  offsets/iterations — if keys don't verify, re-check the params in `references/internals.md`
  rather than guessing.
- **Group chats** work: each sender is shown on the left under their display name, you on the
  right; the internal `<sender>:\n` tag WeChat prefixes to every group message is stripped, and
  system notices (recalls, group management) render as centered grey lines.

## Deeper notes
`references/internals.md` — SQLCipher-4 params, the CCCrypt-hook rationale and anti-debug
traps, zstd/quote message schema, the renderer's overflow fix, and the unsolved image cipher.
Read it when a step misbehaves or you need to extend the pipeline (e.g. embed real images).
