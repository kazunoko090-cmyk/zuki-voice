-- Zuki Voice ランチャー
-- ホットキーから起動する想定。macOSの音声入力（fnキー）の体験を真似る：
--   1. いま使っているアプリを覚える
--   2. ピル型ミニウィンドウ（Chrome app mode）を開く → 話す → ✓ でコピーされて自動で閉じる
--   3. 元のアプリに戻って ⌘V で貼り付け（キャンセル時は何もしない）
-- 初回だけ macOS が「System Events / Chrome の制御」「アクセシビリティ」の許可を聞いてくる。

on run
	-- 1. いまの最前面アプリを覚える
	tell application "System Events"
		set prevApp to name of first application process whose frontmost is true
	end tell

	-- キャンセル検知用の目印をクリップボードに置く
	set the clipboard to "ZV_PENDING"

	-- 2. ピルウィンドウを開く
	do shell script "open -na 'Google Chrome' --args --app='https://zuki-voice.kazunoko090.workers.dev/mini?rec=1' --window-size=440,170"

	-- ピルウィンドウが閉じるまで待つ（最長3分）
	delay 1.2
	set waited to 0
	repeat
		delay 0.4
		set waited to waited + 0.4
		if waited > 180 then exit repeat
		set stillOpen to false
		try
			tell application "Google Chrome"
				repeat with w in windows
					if title of w contains "Zuki Voice ミニ" then set stillOpen to true
				end repeat
			end tell
		end try
		if not stillOpen then exit repeat
	end repeat

	-- 3. コピーされていたら（＝目印が書き換わっていたら）元のアプリに貼り付け
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
