#!/bin/bash
# Zuki Voice ランチャーを入れる／中身だけ更新する
#   ./tools/install-launcher.sh          中身（launcher-core）だけ更新。許可はそのまま
#   ./tools/install-launcher.sh --app    入口アプリも作り直す（初回だけ。アクセシビリティの許可が外れる）
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/ZukiVoice"
APP="/Applications/Zuki Voice.app"

mkdir -p "$DEST"
cp launcher-core.applescript "$DEST/launcher-core.applescript"
echo "中身を更新しました: $DEST/launcher-core.applescript"

if [[ "${1:-}" == "--app" || ! -d "$APP" ]]; then
  rm -rf "$APP"
  osacompile -o "$APP" launcher-entry.applescript
  # Dock に出さず、起動しても前のアプリからフォーカスを奪わない
  plutil -replace LSUIElement -bool true "$APP/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "com.kazunoko090.zukivoice" "$APP/Contents/Info.plist"
  codesign --force --deep --sign - "$APP"
  echo "入口アプリを作り直しました: $APP（アクセシビリティで許可し直してください）"
fi
