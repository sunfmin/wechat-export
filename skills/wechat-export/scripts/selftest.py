#!/usr/bin/env python3
"""Offline functional test for the renderer. No side effects.

Renders references/sample_chat.json and asserts the WeChat-style output holds:
single self-contained file, quote boxes, built-in emoticons mapped to system emoji,
no external resources, message count preserved.

Usage: python3 selftest.py [sample.json]
Exit 0 = PASS, 1 = FAIL.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    HERE, "..", "references", "sample_chat.json")


def load_emoji_map():
    spec = importlib.util.spec_from_file_location(
        "render_html", os.path.join(HERE, "render_html.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # import-safe: rendering runs only under __main__
    return mod.EMOJI


def main():
    spec_msgs = json.load(open(SAMPLE, encoding="utf-8"))["messages"]
    n = len(spec_msgs)
    emoji_map = load_emoji_map()

    out = tempfile.mktemp(suffix=".html")
    r = subprocess.run([sys.executable, os.path.join(HERE, "render_html.py"),
                        SAMPLE, out], capture_output=True, text=True)
    if r.returncode != 0:
        print("render failed:", r.stderr)
        return 1
    html = open(out, encoding="utf-8").read()

    # which bracket tokens in the source are mappable emoticons
    src_text = "".join((m.get("text", "") or "") for m in spec_msgs)
    mappable = {t for t in re.findall(r"\[([^\[\]]{1,8})\]", src_text) if t in emoji_map}

    checks = {
        "single file produced": len(html) > 100,
        "quote boxes rendered": ('class="quote"' in html) or not any(
            "〔回复" in (m.get("text", "") or "") for m in spec_msgs),
        "emoticons mapped to emoji": all(
            emoji_map[t] in html and f"[{t}]" not in html for t in mappable
        ) if mappable else True,
        "no external resources": not re.search(r'(src|href)="https?:', html)
            and "<link" not in html and "<script src" not in html,
        "has viewport (mobile)": "width=device-width" in html,
        "message count preserved": html.count('class="row') >= n,
    }
    ok = all(checks.values())
    for k, v in checks.items():
        print(("  PASS " if v else "  FAIL ") + k)
    if mappable:
        print("  (mapped emoticons tested: " + ", ".join(
            f"[{t}]→{emoji_map[t]}" for t in sorted(mappable)) + ")")
    print("FUNCTIONAL:", "PASS" if ok else "FAIL")
    try:
        os.unlink(out)
    except OSError:
        pass
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
