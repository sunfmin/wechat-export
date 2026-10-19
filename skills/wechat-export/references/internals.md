# WeChat 4.x macOS export — internals & gotchas

Everything here was verified on **WeChat for Mac 4.1.13**, macOS 26 (Darwin 27),
Apple Silicon. Numbers may shift across 4.x point releases — re-verify, don't assume.

## Storage layout
```
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/
    <wxid>_<hash>/                 ← account dir (e.g. wxid_abc123_d844). NEVER hardcode; detect.
        db_storage/                ← ~23 SQLCipher-4 encrypted *.db (message_N, contact, session…)
        msg/attach/.../Img/        ← image/thumbnail .dat files (encrypted, see below)
        msg/video/.../*_thumb.jpg  ← video thumbnails (some plaintext jpg)
```

## SQLCipher-4 parameters (per DB)
- AES-256-CBC, page size 4096, reserve 80 = IV(16) + HMAC-SHA512(64).
- KDF: PBKDF2-HMAC-SHA512, 256000 iterations. Per-DB 16-byte salt = first 16 bytes of file.
- `mac_salt = salt XOR 0x3a`.
- One account master → every DB's key: `enc_key_i = PBKDF2(password, salt_i, 256000, 32)`.
- Page-1 verify:
  `mac_key = pbkdf2_hmac('sha512', enc_key, salt^0x3a, 2, 32)`;
  `HMAC(mac_key, page1[16 : 4096-80+16] + struct.pack('<I',1))` must equal `page1[4096-64:4096]`.

## Getting the key (what actually works on 4.1.13)
- **Hook `CCCrypt` / `CCCryptorCreate` / `CCCryptorCreateWithMode`** (CommonCrypto AES) with
  **Frida**, filter `alg==0` (AES) and `keyLength==32`. These fire continuously on page reads,
  so an **attach** (not launch) captures keys as you browse. Tool: `wechat-key-macos`
  (`scripts/extract_key.py`). It verifies each candidate against page-1 HMAC before writing.
- `CCKeyDerivationPBKDF` only fires at DB-open (startup) — less reliable; CCCrypt is the win.
- **Prereqs:** root (Frida needs `task_for_pid`, not ptrace), WeChat re-signed ad-hoc with
  `get-task-allow`, and **frida < 17** (17+ broke this flow here).
- **Anti-debug:** WeChat detects `P_TRACED` and relaunches a clean copy via LaunchServices, so
  `lldb`-as-launch dies in ~2s; as root the relaunch fails but lands in the wrong `/var/root`
  container. CCCrypt-via-attach sidesteps all of it.
- **Sandbox:** WeChat is sandbox-restricted → `DYLD_INSERT_LIBRARIES` is stripped, so dylib
  injection is a dead end. Frida attach is the route.
- `key_info.db` (plaintext `LoginKeyInfoTable`) does **not** contain the DB key — it's login
  credential material. Dead end; don't chase it.

## Decrypt + export (wxbak = wechat4-db-export)
- `--data-dir <account dir>` is a **global** arg → it goes BEFORE the subcommand.
- `refresh` decrypts all DBs including `-wal` (recent messages live in WAL; a raw page-1
  decrypt misses them). It may print a Windows-path `FileNotFoundError` at the very end — the
  decryption already succeeded; the trailing error is cosmetic.
- `list` → resolve a person (备注/昵称/微信号/wxid) to their conversation.
- `export --who <name> --format json --out DIR` → one conversation as JSON.
- Keys file location: `$WXBAK_HOME/keys/<accountname>.json`; the `extract_key.py` output
  format matches it 1:1.
- wxbak also has its own `extract` and a one-shot `all` (extract→refresh→export). Try it first
  if you like; fall back to the CCCrypt path above when its in-memory extraction misses on a
  given build.

## Message schema (decrypted)
- One conversation = table `Msg_<md5(username)>`, may span several `message_N.db` shards.
- **username ≠ 微信号.** 微信号 is `alias`; the Msg-table hash uses the internal `username`
  (resolve via the contact DB / wxbak list).
- `local_type`: 1=text, 3=image, 34=voice, 43=video, 47=sticker, 48=location, 49=appmsg,
  10000=system. Quote replies carry a composite `local_type = 244813135921` (= 49 with a
  subtype in the high bits).
- `message_content` is often **zstd-compressed**, flagged by the sibling column
  `WCDB_CT_message_content == 4`. Decompress with zstandard before parsing XML.
- Quote reply XML: `<appmsg><title>你的回复</title><refermsg><type>N</type>
  <displayname>…</displayname><content>被引用原文</content></refermsg></appmsg>`. The
  `refermsg` `<type>` tells you what was quoted (1 text, 3 image, 43 video, 34 voice, 49 link).
  wxbak flattens text quotes to `正文  〔回复 名字：原文〕`; the renderer turns that back into a
  grey quote box.

## Rendering (render_html.py)
- Self-contained single HTML, no external assets. Me = green right, other = white left, date
  dividers, full date+time per row, `viewport` + safe-area for mobile, `@media print` for
  Save-as-PDF.
- Built-in emoticons `[微笑]`→🙂 etc via the `EMOJI` map (closest system emoji; renders native
  colour on iOS/Android). Native unicode emoji already in the text pass through; an emoji font
  fallback is declared.
- `word-break` + `min-width:0` on flex children prevent the long-CJK horizontal-overflow bug.
  (Chrome headless `innerWidth` has a 500px floor — a 390px screenshot of it will clip
  right-aligned bubbles; that's a screenshot artifact, not a layout bug. Verify overflow with
  `scrollWidth <= innerWidth`, not by eye.)

## Known-unsolved (future work)
- **Media are text placeholders** (`[图片]`/`[视频]`/`[语音]`). Embedding real images needs
  the image cipher below.
- **Image/thumbnail `.dat` is AES, format "V2"** (header `07 08 56 32`). The per-message
  `aeskey` in the XML does NOT decrypt the local `.dat`, and the image key is NOT derivable
  from the DB keys — it needs a **separate capture** (hook AES during image view). Disk
  filenames use the `hardlink` DB's hash, not the message `md5`, so mapping message→file also
  needs the hardlink DB. Not yet implemented.

## Safety / cleanup
- Operate read-only: copy DBs out, never write into the live `db_storage`. Back it up first.
- When done, **restore WeChat's signature** — `codesign -f -s - --deep /Applications/WeChat.app`
  removes the `get-task-allow` entitlement (with it set, WeChat's own anti-debug may refuse to
  launch). The cleanest restore is to **reinstall WeChat** (genuine Tencent signature back);
  chat data is untouched by any of this.
