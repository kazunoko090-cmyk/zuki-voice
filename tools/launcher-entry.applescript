-- Zuki Voice 入口アプリ（/Applications/Zuki Voice.app）
-- macOS のアクセシビリティ許可はこのアプリに付く。作り直すと許可が外れるので、
-- ここには何も足さないこと。処理を変えたいときは launcher-core.applescript を直す。
on run
	try
		run script (POSIX file ((POSIX path of (path to application support folder from user domain)) & "ZukiVoice/launcher-core.applescript"))
	on error errMsg number errNum
		try
			do shell script "echo " & quoted form of ((do shell script "date '+%F %T'") & "  " & errNum & "  " & errMsg) & " >> ~/Library/Logs/ZukiVoice.log"
		end try
	end try
end run
