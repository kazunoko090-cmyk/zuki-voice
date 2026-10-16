-- Zuki Voice ランチャーの中身（トグル式）
-- 入口アプリ /Applications/Zuki Voice.app がこのファイルを `run script` で読み込んで実行する。
-- 入口アプリは作り直さないので、ここを書き換えてもアクセシビリティ許可は外れない。
-- 実際に読み込まれるのは ~/Library/Application Support/ZukiVoice/launcher-core.applescript
-- （tools/install-launcher.sh でコピーする）。
--
-- macOSの音声入力（fnキー）の体験を真似る：
--   1回目: いま使っているアプリを覚える → 画面下中央に小さなピルを開く → 話す
--   2回目: 開いているピルに Enter を送る（＝✓確定）→ 整形→コピー→自動で閉じる
--   閉じたのを見届けて、元のアプリに ⌘V で貼り付け。キャンセル時は元のクリップボードに戻す

property pillTitle : "Zuki Voice ミニ"
property pillURL : "https://zuki-voice.kazunoko090.workers.dev/mini?rec=1"
property chromeBin : "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
property pillW : 220
property pillH : 96
property marker : "ZV_PENDING"

on pillOpen()
	try
		tell application "System Events"
			if not (exists process "Google Chrome") then return false
			tell process "Google Chrome"
				return (count of (windows whose name contains pillTitle)) > 0
			end tell
		end tell
	end try
	return false
end pillOpen

on confirmPill()
	tell application "System Events"
		tell process "Google Chrome"
			set frontmost to true
			perform action "AXRaise" of (first window whose name contains pillTitle)
		end tell
		delay 0.12
		key code 36 -- Return
	end tell
end confirmPill

on openPill()
	-- 画面下中央の位置（権限のいらない NSScreen で画面サイズを取る）
	set sz to do shell script "osascript -l JavaScript -e 'ObjC.import(\"AppKit\"); var f=$.NSScreen.mainScreen.visibleFrame; Math.round(f.size.width)+\",\"+Math.round(f.size.height)'"
	set AppleScript's text item delimiters to ","
	set sw to (text item 1 of sz) as integer
	set sh to (text item 2 of sz) as integer
	set AppleScript's text item delimiters to ""
	set px to (sw - pillW) div 2
	set py to sh - pillH - 40
	-- Chrome本体を直接呼ぶ（起動中なら既存のChromeに「小さなアプリ窓を開いて」と渡して即終了する）
	do shell script quoted form of chromeBin & " --app=" & quoted form of pillURL & " --window-size=" & pillW & "," & pillH & " --window-position=" & px & "," & py & " > /dev/null 2>&1 &"
end openPill

on run
	-- ===== 2回目の押下：開いているピルを確定して終わり =====
	if pillOpen() then
		confirmPill()
		return
	end if

	-- ===== 1回目の押下 =====
	tell application "System Events"
		set prevApp to name of first application process whose frontmost is true
	end tell

	-- 元のクリップボード（文字）を覚えておき、キャンセル検知用の目印を置く
	set oldClip to missing value
	try
		set oldClip to (the clipboard as text)
	end try
	set the clipboard to marker

	openPill()

	-- ピルが現れるのを待つ（最長6秒）→ 閉じるまで待つ（最長5分半）
	set waited to 0
	repeat until pillOpen() or waited > 6
		delay 0.2
		set waited to waited + 0.2
	end repeat
	set waited to 0
	repeat while pillOpen()
		delay 0.25
		set waited to waited + 0.25
		if waited > 330 then exit repeat
	end repeat

	delay 0.15
	set clip to marker
	try
		set clip to (the clipboard as text)
	end try

	if clip is not marker and clip is not "" then
		-- 確定：元のアプリに戻して貼り付け
		tell application "System Events"
			set frontmost of process prevApp to true
			delay 0.25
			keystroke "v" using command down
		end tell
	else
		-- キャンセル・失敗：クリップボードを元に戻す
		if oldClip is not missing value then set the clipboard to oldClip
	end if
end run
