#!/usr/bin/env python3
"""Render a wxbak JSON chat export into a self-contained WeChat-style HTML transcript.

Single file, mobile-friendly, zero external assets. WeChat-style bubbles (me = green
right, other = white left), date dividers, built-in emoticons [xxx] mapped to system
emoji, quote replies rendered as WeChat's grey quote box, full date+time per row.
Also carries an @media print block so a browser can Save-as-PDF with a compact layout.

Usage: render_html.py <wxbak_export.json> <out.html>

Importable: the EMOJI map and esc() are module-level; rendering runs only under __main__.
"""
import html
import json
import re
import sys

# 微信内置表情 [xxx] → 最接近的系统 emoji（手机原生彩色渲染，零外部依赖）
EMOJI = {
    "拥抱": "🤗", "裂开": "🫠", "亲亲": "😘", "Kiss": "😘", "菜刀": "🔪",
    "偷笑": "🤭", "苦涩": "😖", "憨笑": "😄", "害羞": "😊", "难过": "😔",
    "破涕为笑": "🥲", "呲牙": "😁", "捂脸": "🤦", "囧": "😵", "OK": "👌",
    "抱拳": "🙏", "凋谢": "🥀", "流泪": "😭", "尴尬": "😬", "晕": "😵‍💫",
    "困": "😪", "旺柴": "🐶", "擦汗": "😓", "鼓掌": "👏", "傲慢": "😏",
    "勾引": "😉", "得意": "😎", "爱心": "❤️", "委屈": "🥺", "强": "👍",
    "微笑": "🙂", "耶": "✌️", "敲打": "😣",
    # 常见补充（不同聊天未必出现，稳妥起见）
    "愉快": "😊", "可爱": "☺️", "色": "😍", "发呆": "😳", "大哭": "😭",
    "害怕": "😱", "哈欠": "🥱", "坏笑": "😏", "疑问": "🤨", "嘘": "🤫",
    "衰": "🫥", "骷髅": "💀", "敲": "🔨", "再见": "👋", "鄙视": "🙄",
    "哼": "😤", "可怜": "🥺", "撇嘴": "😒", "睡": "😴", "吐": "🤮",
    "调皮": "😜", "惊讶": "😮", "咒骂": "🤬", "发怒": "😡", "嘿哈": "😆",
    "奸笑": "😏", "机智": "🤓", "皱眉": "😟", "耶耶": "✌️", "送花": "💐",
    "玫瑰": "🌹", "太阳": "☀️", "月亮": "🌙", "咖啡": "☕", "蛋糕": "🎂",
    "礼物": "🎁", "庆祝": "🎉", "鞭炮": "🧨", "烟花": "🎆", "福": "🧧",
    "嘴唇": "💋", "心碎": "💔", "拳头": "✊", "握手": "🤝", "胜利": "✌️",
    "抠鼻": "🤭", "鼓励": "💪", "加油": "💪", "赞": "👍", "差劲": "👎",
    "笑脸": "😊", "脸红": "😊", "叹气": "😮‍💨", "吃瓜": "🍉", "加油鸭": "🦆",
}
_EMO_RE = re.compile(r"\[([^\[\]]{1,8})\]")
# 引用：  正文  〔回复 名字：被引用原文〕
_QUOTE_RE = re.compile(r"^(.*?)\s*〔回复\s*(.+?)：(.*)〕\s*$", re.S)


def _emojify(escaped):
    return _EMO_RE.sub(lambda m: EMOJI.get(m.group(1), m.group(0)), escaped)


def esc(t):
    return _emojify(html.escape(t or "").replace("\n", "<br>"))


STYLE = """
  @page { size: A4; margin: 14mm 12mm; }
  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  html, body { overflow-x: hidden; }
  body { font-family: "PingFang SC","Heiti SC","Hiragino Sans GB",
         "Apple Color Emoji","Segoe UI Emoji","Noto Color Emoji",sans-serif;
         background:#ededed; margin:0; color:#111; font-size:21px;
         max-width:820px; margin-left:auto; margin-right:auto; }
  .head { background:#fff; padding:16px 20px; border-bottom:1px solid #ddd;
          padding-left:max(20px, env(safe-area-inset-left));
          padding-right:max(20px, env(safe-area-inset-right)); }
  .head h1 { margin:0 0 5px; font-size:21px; }
  .head .meta { color:#888; font-size:14px; line-height:1.6; word-break:break-all; }
  .wrap { padding:10px 16px;
          padding-left:max(16px, env(safe-area-inset-left));
          padding-right:max(16px, env(safe-area-inset-right)); }
  .day { text-align:center; margin:14px 0 8px; font-size:12px; color:#999; }
  .row { display:flex; margin:7px 0; }
  .row.you { justify-content:flex-start; }
  .row.me { justify-content:flex-end; }
  .msg { max-width:76%; min-width:0; }
  .name { font-size:14px; color:#888; margin:0 2px 3px; }
  .bubble { padding:11px 14px; border-radius:7px; white-space:normal;
             word-break:break-word; line-height:1.55; font-size:20px; }
  .you .bubble { background:#fff; }
  .me .bubble { background:#95ec69; text-align:left; }
  .quote { margin-top:7px; padding:6px 9px; border-radius:4px;
            background:rgba(0,0,0,0.05); color:#888; font-size:17px;
            line-height:1.45; border-left:3px solid #ccc;
            word-break:break-word; overflow-wrap:anywhere; }
  .me .quote { background:rgba(0,0,0,0.08); }
  .tm { font-size:13px; color:#b0b0b0; margin:3px 3px 0; }
  .me .tm { text-align:right; }
  @media print { body { font-size:12px; max-width:none; }
    .head .meta { font-size:11px; } .bubble { font-size:12.5px; }
    .name { font-size:10px; } .tm { font-size:9px; } .quote { font-size:11px; } }
"""


def render(d):
    """d = wxbak export dict (keys: remark/nick/alias/wxid/messages) → HTML string."""
    meta = d if isinstance(d, dict) else {}
    msgs = d["messages"] if isinstance(d, dict) and "messages" in d else (
        d if isinstance(d, list) else next(v for v in d.values() if isinstance(v, list)))

    title = meta.get("remark") or meta.get("nick") or meta.get("name") or "聊天记录"
    sub = []
    for k in ("nick", "alias", "wxid"):
        if meta.get(k):
            sub.append({"nick": "昵称", "alias": "微信号", "wxid": "wxid"}[k] + "：" + str(meta[k]))
    span = f'{msgs[0]["time"]} ~ {msgs[-1]["time"]}' if msgs else ""

    rows = []
    cur_date = None
    for m in msgs:
        t = m.get("time", "")
        date = t[:10]
        if date != cur_date:
            cur_date = date
            rows.append(f'<div class="day">{esc(date)}</div>')
        side = "me" if m.get("is_self") else "you"
        speaker = esc(m.get("speaker", ""))
        raw = m.get("text", "") or ""
        quote_html = ""
        q = _QUOTE_RE.match(raw)
        if q and "〔回复" not in q.group(1):
            reply, qname, qorig = q.group(1), q.group(2), q.group(3)
            body = esc(reply)
            quote_html = f'<div class="quote">{esc(qname)}：{esc(qorig)}</div>'
        else:
            body = esc(raw)
        name_html = "" if m.get("is_self") else f'<div class="name">{speaker}</div>'
        rows.append(
            f'<div class="row {side}">'
            f'<div class="msg">{name_html}<div class="bubble">{body}{quote_html}</div>'
            f'<div class="tm">{esc(t)}</div></div></div>'
        )

    sub_html = "　".join(esc(s) for s in sub)
    return (
        f'<!doctype html><html lang="zh"><head><meta charset="utf-8">\n'
        f'<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
        f'<title>与 {esc(title)} 的聊天记录</title>\n<style>{STYLE}</style></head><body>\n'
        f'<div class="head"><h1>与 {esc(title)} 的聊天记录</h1>\n'
        f'<div class="meta">{sub_html}<br>消息数：{len(msgs)}　时间：{esc(span)}</div></div>\n'
        f'<div class="wrap">\n{"".join(rows)}\n</div></body></html>'
    ), len(msgs)


def main(argv):
    if len(argv) < 3:
        sys.exit("usage: render_html.py <wxbak_export.json> <out.html>")
    src, out_html = argv[1], argv[2]
    d = json.load(open(src, encoding="utf-8"))
    doc, n = render(d)
    open(out_html, "w", encoding="utf-8").write(doc)
    print(f"wrote {out_html}  ({n} msgs, {len(doc)//1024} KB)")


if __name__ == "__main__":
    main(sys.argv)
