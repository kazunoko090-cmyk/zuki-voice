-- Zuki Voice ランチャー（トグル式）
-- Karabiner の fn 単体タップから `open -na '/Applications/Zuki Voice.app'` で起動する想定。
-- macOSの音声入力（fnキー）の体験を真似る：
--   1回目: いま使っているアプリを覚える → 画面下中央に小さなピルを開く → 話す
--   2回目: 開いているピルに Enter を送る（＝✓確定）→ 整形→コピー→自動で閉じる
--   閉じたのを見届けて、元のアプリに ⌘V で貼り付け（キャンセル時は何もしない）
-- Chrome への Apple Events は使わない（許可が1つ減る）。System Events だけで動くので、
-- 初回に「アクセシビリティ」で Zuki Voice を許可すればOK。

property pillTitle : "Zuki Voice ミニ"
property pillURL : "https://zuki-voice.kazunoko090.workers.dev/mini?rec=1"
property chromeBin : "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
property pillW : 440
property pillH : 190

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

on run
	-- ===== 2回目の押下：開いているピルに確定（Enter）を送って終わり =====
	if pillOpen() then
		try
			tell application "System Events"
				tell process "Google Chrome"
					set frontmost to true
					perform action "AXRaise" of (first window whose name contains pillTitle)
				end tell
				delay 0.15
				key code 36 -- Return
			end tell
		end try
		return
	end if

	-- ===== 1回目の押下：ピルを開く =====
	tell application "System Events"
		set prevApp to name of first application process whose frontmost is true
	end tell

	-- キャンセル検知用の目印をクリップボードに置く
	set the clipboard to "ZV_PENDING"

	-- 画面下中央の位置を計算（権限のいらない NSScreen で画面サイズを取る）
	set sz to do shell script "osascript -l JavaScript -e 'ObjC.import(\"AppKit\"); var f=$.NSScreen.mainScreen.visibleFrame; Math.round(f.size.width)+\",\"+Math.round(f.size.height)'"
	set AppleScript's text item delimiters to ","
	set sw to (text item 1 of sz) as integer
	set sh to (text item 2 of sz) as integer
	set AppleScript's text item delimiters to ""
	set px to (sw - pillW) div 2
	set py to sh - pillH - 60

	-- Chrome本体を直接呼ぶ（起動中なら既存のChromeに「小さなアプリ窓を開いて」と渡して即終了する）
	do shell script quoted form of chromeBin & " --app=" & quoted form of pillURL & " --window-size=" & pillW & "," & pillH & " --window-position=" & px & "," & py & " > /dev/null 2>&1 &"

	-- ピルが現れるのを待つ（最長5秒）→ 閉じるまで待つ（最長5分）
	set waited to 0
	repeat until pillOpen() or waited > 5
		delay 0.25
		set waited to waited + 0.25
	end repeat
	set waited to 0
	repeat while pillOpen()
		delay 0.3
		set waited to waited + 0.3
		if waited > 300 then exit repeat
	end repeat

	-- コピーされていたら（＝目印が書き換わっていたら）元のアプリに貼り付け
	delay 0.2
	set clip to "ZV_PENDING"
	try
		set clip to (the clipboard as text)
	end try
	if clip is not "ZV_PENDING" and clip is not "" then
		try
			tell application "System Events"
				set frontmost of process prevApp to true
				delay 0.3
				keystroke "v" using command down
			end tell
		end try
	end if
end run
