#!/usr/bin/env python3
"""Zuki Voice の個人辞書に言葉を足す（消す）。4か所を一度にそろえる。

  python3 tools/add-word.py --r 備考 --w 美行、びこう
  python3 tools/add-word.py --r 上記 --w 蒸気 --ctx "の件|の内容|適用"
  python3 tools/add-word.py --r サンキューカード            # 読み方なし（聞き取りのヒントだけ）
  python3 tools/add-word.py --remove 備考

  --r    正しい表記（入力してほしい文字）
  --w    よく間違えられる表記・読み（、区切りで複数）
  --ctx  後ろに続く言葉（| 区切り）。付けると「w の直後が ctx のときだけ」機械的に r に置き換える。
         同じ読みで実在する別の言葉（蒸気・探究・A など）は必ず ctx を付ける

そろえる4か所:
  1. ~/Library/Application Support/ZukiVoice/dict.json  … Mac アプリ（fn）が毎回読む本体。すぐ効く
  2. public/app.html の DICT_SEED（DICT_SEED_VER を +1）  … ブラウザ版。deploy 後に効く
  3. public/mini.html の DICT_FALLBACK                     … 予備ページ
  4. native/main.swift の seedDict                         … 次にアプリを作り直したときの初期値
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DICT_JSON = os.path.expanduser("~/Library/Application Support/ZukiVoice/dict.json")
APP = os.path.join(ROOT, "public/app.html")
MINI = os.path.join(ROOT, "public/mini.html")
SWIFT = os.path.join(ROOT, "native/main.swift")


def entry(r, w, ctx):
    e = {"r": r}
    if w:
        e["w"] = w
    if ctx:
        e["ctx"] = ctx
    return e


def js_obj(e, spaced):
    parts = []
    for k in ("r", "w", "ctx"):
        if k in e:
            parts.append(("%s: %s" if spaced else "%s:%s") % (k, json.dumps(e[k], ensure_ascii=False)))
    return ("{ %s }" if spaced else "{%s}") % (", " if spaced else ",").join(parts)


def swift_obj(e):
    return "[%s]" % ", ".join('"%s": %s' % (k, json.dumps(e[k], ensure_ascii=False)) for k in ("r", "w", "ctx") if k in e)


def drop_line_entries(text, start_marker, end_marker, r, pattern):
    i = text.index(start_marker)
    j = text.index(end_marker, i)
    block = text[i:j]
    block2 = re.sub(pattern % re.escape(json.dumps(r, ensure_ascii=False)), "", block)
    block2 = re.sub(r"\n[ \t]*(?=\n)", "", block2)  # 消した跡の空行を詰める
    return text[:i] + block2 + text[j:], block2 != block


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--r")
    ap.add_argument("--w", default="")
    ap.add_argument("--ctx", default="")
    ap.add_argument("--remove")
    a = ap.parse_args()
    r = (a.remove or a.r or "").strip()
    if not r:
        sys.exit("--r（正しい表記）か --remove を指定してください")
    e = None if a.remove else entry(r, a.w.strip(), a.ctx.strip())

    # 1. Mac アプリの辞書
    d = json.load(open(DICT_JSON, encoding="utf-8")) if os.path.exists(DICT_JSON) else []
    d = [x for x in d if x.get("r") != r]
    if e:
        d.append(e)
    os.makedirs(os.path.dirname(DICT_JSON), exist_ok=True)
    json.dump(d, open(DICT_JSON, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    # 2. app.html（1行1語・版を上げる）
    s = open(APP, encoding="utf-8").read()
    s, _ = drop_line_entries(s, "const DICT_SEED = [", "\n];", r, r"\n  \{ r: %s[^\n]*")
    if e:
        j = s.index("\n];", s.index("const DICT_SEED = ["))
        s = s[:j] + "\n  " + js_obj(e, True) + "," + s[j:]
    m = re.search(r"const DICT_SEED_VER = (\d+);", s)
    ver = int(m.group(1)) + 1
    s = s.replace(m.group(0), "const DICT_SEED_VER = %d;" % ver, 1)
    open(APP, "w", encoding="utf-8").write(s)

    # 3. mini.html（1行に詰めて書いてある）
    s = open(MINI, encoding="utf-8").read()
    s, _ = drop_line_entries(s, "const DICT_FALLBACK=[", "\n];", r, r",?\{r:%s[^}]*\}")
    if e:
        j = s.index("\n];", s.index("const DICT_FALLBACK=["))
        s = s[:j] + "," + js_obj(e, False) + s[j:]
    s = s.replace("[\n  ,", "[\n  ")
    open(MINI, "w", encoding="utf-8").write(s)

    # 4. main.swift
    s = open(SWIFT, encoding="utf-8").read()
    s, _ = drop_line_entries(s, "let seedDict: [[String: String]] = [", "\n]", r, r"\[\"r\": %s[^\]]*\],? ?")
    if e:
        j = s.index("\n]", s.index("let seedDict: [[String: String]] = ["))
        s = s[:j] + "\n    " + swift_obj(e) + "," + s[j:]
    open(SWIFT, "w", encoding="utf-8").write(s)

    print(("消しました: " if a.remove else "登録しました: ") + json.dumps(e or {"r": r}, ensure_ascii=False))
    print("Mac アプリ: %d 語（すぐ効く） / ブラウザ版 DICT_SEED_VER=%d（deploy 後に効く）" % (len(d), ver))


if __name__ == "__main__":
    main()
