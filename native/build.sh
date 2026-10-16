#!/bin/bash
# Zuki Voice ネイティブアプリをビルドして /Applications に入れる
#   ./native/build.sh
# 署名は ad-hoc だが、指定要件（designated requirement）をバンドルIDだけにしておくことで、
# 作り直してもマイク・アクセシビリティの許可が外れにくくしている。
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/Zuki Voice.app"
BUILD="$(mktemp -d)"
BID="com.kazunoko090.zukivoice.app"

# Command Line Tools の既知の不具合（include/swift に module.modulemap と bridging.modulemap が
# 二重にあって「redefinition of module 'SwiftBridging'」になる）を、システムを触らずに
# 古い方を空ファイルに見せかけて回避する。SDK はコンパイラと版が合う 15.2 を使う。
cat > "$BUILD/vfs.yaml" <<'EOF'
{ "version": 0, "case-sensitive": "false", "roots": [
  { "name": "/Library/Developer/CommandLineTools/usr/include/swift", "type": "directory",
    "contents": [ { "name": "module.modulemap", "type": "file", "external-contents": "/dev/null" } ] } ] }
EOF
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"

swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -sdk "$SDK" \
  -Xcc -ivfsoverlay -Xcc "$BUILD/vfs.yaml" -vfsoverlay "$BUILD/vfs.yaml" \
  -o "$BUILD/ZukiVoice" main.swift \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework ServiceManagement

pkill -x ZukiVoice 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD/ZukiVoice" "$APP/Contents/MacOS/ZukiVoice"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier "$BID" \
  -r="designated => identifier \"$BID\"" "$APP"
rm -rf "$BUILD"
echo "インストールしました: $APP"
