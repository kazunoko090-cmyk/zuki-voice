#!/bin/bash
# 本番の整形（/api/polish）に、Mac アプリと同じ辞書で文を流して結果を見る。
#   ./tools/try.sh "蒸気の件、了解です" "加湿器の蒸気が強すぎる"
# 1行に「入力 → 出力 [エンジン]」が出る。エンジンが claude 以外なら Claude が失敗している。
set -euo pipefail
DICT="$HOME/Library/Application Support/ZukiVoice/dict.json"
API="https://zuki-voice.kazunoko090.workers.dev/api/polish"
for t in "$@"; do
  body=$(/usr/bin/python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(json.dumps({"text":sys.argv[2],"style":"clean","dict":d},ensure_ascii=False))' "$DICT" "$t")
  out=$(curl -s -X POST "$API" -H 'content-type: application/json' \
    -H 'user-agent: Mozilla/5.0 (Macintosh) ZukiVoice/1.0' --data "$body" \
    | /usr/bin/python3 -I -c 'import json,sys;d=json.load(sys.stdin);print(d.get("text"),"["+str(d.get("engine"))+"]")')
  echo "$t → $out"
done
