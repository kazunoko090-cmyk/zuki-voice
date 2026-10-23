// Zuki Voice — macOS ネイティブのピル（fn で録音 → もう一度 fn で確定 → 元の場所に貼り付け）
//
// ・Karabiner の fn 単体タップが Darwin 通知 "com.kazunoko090.zukivoice.toggle" を送ってくる
// ・ピルは右下に浮かぶ小さなパネル。前のアプリからフォーカスを奪わない（だから貼り付け先がずれない）
// ・録音は Mac 内蔵マイクを直接指定（連係カメラの iPhone マイクを拾わない）
// ・文字起こし／整形はサーバー（Cloudflare Worker）の /api/transcribe と /api/polish を使う
// ・個人辞書は ~/Library/Application Support/ZukiVoice/dict.json（無ければ初期語彙で作る）

import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import ServiceManagement

let API = "https://zuki-voice.kazunoko090.workers.dev"
let toggleNote = "com.kazunoko090.zukivoice.toggle"
let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ZukiVoice")
let maxRecordSeconds: TimeInterval = 300

// 動作の記録（~/Library/Logs/ZukiVoice.log）。うまく動かないときの手がかり用
// 誤変換を直すときに「何と聞き取られたか」を見たいので直近は残すが、
// 話した内容が溜まり続けないよう、64KB を超えたら新しい方の 300 行だけにする
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ZukiVoice.log")
let logMaxBytes = 64 * 1024
let logKeepLines = 300

func trimLog() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
          let size = attrs[.size] as? Int, size > logMaxBytes,
          let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
    let kept = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(logKeepLines).joined(separator: "\n") + "\n"
    try? kept.write(to: logURL, atomically: true, encoding: .utf8)
}

func zlog(_ msg: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date()))  \(msg)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.data(using: .utf8)!.write(to: logURL) }
    trimLog()
}

// サーバーの合言葉。~/Library/Application Support/ZukiVoice/key に1行で置く（無ければ送らない）
func appKey() -> String? {
    guard let s = try? String(contentsOf: supportDir.appendingPathComponent("key"), encoding: .utf8) else { return nil }
    let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return k.isEmpty ? nil : k
}

// MARK: - 個人辞書

let seedDict: [[String: String]] = [
    ["r": "Zuki Voice", "w": "ずきぼいす"], ["r": "JOOM", "w": "じゅーむ"], ["r": "Shopee", "w": "しょっぴー"],
    ["r": "eBay", "w": "いーべい"], ["r": "クーパン", "w": "Coupang"], ["r": "チャットワーク"], ["r": "クラウドワークス"],
    ["r": "Cloudflare", "w": "クラウドフレア"], ["r": "駿河屋"], ["r": "オークファン"], ["r": "一番くじ"], ["r": "遊戯王"], ["r": "ポケカ"],
    ["r": "Wise", "w": "ワイズ、YS"], ["r": "絵", "w": "A", "ctx": "を追加|を1枚|を一枚|を2枚|を二枚|を何枚|を入れ|を差し替|の差し替|を描|を貼|を変え|をもう少し|をもっと|を作って|を消して"],
    ["r": "上記", "w": "蒸気", "ctx": "の件|の内容|の通り|のとおり|適用|で問題|でお願い|を参照|に記載|記載|をご確認|を確認"],
    ["r": "サンキューカード"], ["r": "サンキュー", "w": "探究、探求", "ctx": "カード"],
    ["r": "備考", "w": "美行、びこう"],
    
]

func loadDict() -> [[String: String]] {
    let url = supportDir.appendingPathComponent("dict.json")
    if let d = try? Data(contentsOf: url),
       let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] {
        return arr
    }
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    if let d = try? JSONSerialization.data(withJSONObject: seedDict, options: [.prettyPrinted, .withoutEscapingSlashes]) {
        try? d.write(to: url)
    }
    return seedDict
}

// MARK: - 内蔵マイクを探す

func builtInInputDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids {
        var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                               mScope: kAudioDevicePropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
        var sSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize)
        if sSize == 0 { continue }
        var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &t) == noErr, t == kAudioDeviceTransportTypeBuiltIn {
            return id
        }
    }
    return nil
}

// MARK: - 録音（16kHz モノラル WAV に変換しながら書く）

enum RecError: Error { case noInput }

final class Recorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var url: URL
    var onLevel: ((Float) -> Void)?
    var peak: Float = 0

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zv-\(UUID().uuidString).wav")
    }

    func start() throws {
        let input = engine.inputNode
        if let dev = builtInInputDevice(), let au = input.audioUnit {
            var d = dev
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFmt = input.inputFormat(forBus: 0)
        zlog("入力: device=\(builtInInputDevice().map { String($0) } ?? "既定") format=\(inFmt)")
        guard inFmt.channelCount > 0, inFmt.sampleRate > 0 else { throw RecError.noInput }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        file = f
        let outFmt = f.processingFormat
        converter = AVAudioConverter(from: inFmt, to: outFmt)

        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { [weak self] buf, _ in
            self?.handle(buf, outFmt: outFmt)
        }
        engine.prepare()
        try engine.start()
    }

    private func handle(_ buf: AVAudioPCMBuffer, outFmt: AVAudioFormat) {
        if let ch = buf.floatChannelData?[0] {
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let level = min(1, sqrt(sum / Float(max(n, 1))) * 14)
            if level > peak { peak = level }
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        guard let conv = converter, let file = file else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * outFmt.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if out.frameLength > 0 { try? file.write(from: out) }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // ここでWAVが閉じられる
        converter = nil
    }

    func discard() {
        stop()
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - ピルの部品

final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WaveView: NSView {
    private var levels = [Float](repeating: 0, count: 14)
    func push(_ l: Float) { levels.removeFirst(); levels.append(l); needsDisplay = true }
    func reset() { levels = levels.map { _ in 0 }; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        let n = levels.count
        let bw = bounds.width / CGFloat(n)
        for i in 0..<n {
            let h = max(2.5, CGFloat(levels[i]) * bounds.height)
            let r = NSRect(x: CGFloat(i) * bw + bw * 0.3, y: (bounds.height - h) / 2, width: bw * 0.4, height: h)
            NSBezierPath(roundedRect: r, xRadius: bw * 0.2, yRadius: bw * 0.2).fill()
        }
    }
}

final class CircleButton: NSView {
    enum Kind { case cancel, ok }
    let kind: Kind
    var action: (() -> Void)?
    var enabled = true { didSet { alphaValue = enabled ? 1 : 0.4 } }

    init(frame: NSRect, kind: Kind) { self.kind = kind; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if enabled { action?() } }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor = kind == .ok ? .white : NSColor(white: 0.23, alpha: 1)
        let fg: NSColor = kind == .ok ? .black : .white
        bg.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let p = NSBezierPath()
        let s = bounds.width
        p.lineWidth = s * 0.1
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        if kind == .cancel {
            p.move(to: NSPoint(x: s * 0.35, y: s * 0.35)); p.line(to: NSPoint(x: s * 0.65, y: s * 0.65))
            p.move(to: NSPoint(x: s * 0.65, y: s * 0.35)); p.line(to: NSPoint(x: s * 0.35, y: s * 0.65))
        } else {
            p.move(to: NSPoint(x: s * 0.3, y: s * 0.5))
            p.line(to: NSPoint(x: s * 0.44, y: s * 0.36))
            p.line(to: NSPoint(x: s * 0.7, y: s * 0.64))
        }
        fg.setStroke()
        p.stroke()
    }
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum State { case idle, recording, busy }

    let W: CGFloat = 136, H: CGFloat = 32
    var panel: PillPanel!
    var wave: WaveView!
    var label: NSTextField!
    var spinner: NSProgressIndicator!
    var okBtn: CircleButton!
    var xBtn: CircleButton!

    var state: State = .idle
    var recorder: Recorder?
    var autoStop: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        trimLog()
        buildPanel()
        _ = loadDict()
        registerToggle()
        // 貼り付け（⌘V を送る）にはアクセシビリティ許可が要る。未許可なら一度だけ案内が出る
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if #available(macOS 13.0, *) { try? SMAppService.mainApp.register() } // ログイン時に自動起動
        if CommandLine.arguments.contains("--toggle") { toggle() }
    }

    // fn（Karabiner）からの合図を受け取る
    func registerToggle() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer = observer else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
        }, toggleNote as CFString, nil, .deliverImmediately)
    }

    func buildPanel() {
        panel = PillPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.cgColor
        bg.layer?.cornerRadius = H / 2
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor(white: 1, alpha: 0.2).cgColor
        panel.contentView = bg

        let b: CGFloat = 24, pad: CGFloat = 4
        xBtn = CircleButton(frame: NSRect(x: pad, y: pad, width: b, height: b), kind: .cancel)
        xBtn.action = { [weak self] in self?.cancel() }
        okBtn = CircleButton(frame: NSRect(x: W - pad - b, y: pad, width: b, height: b), kind: .ok)
        okBtn.action = { [weak self] in self?.finish() }

        let midX = pad + b + 6, midW = W - 2 * (pad + b + 6)
        wave = WaveView(frame: NSRect(x: midX, y: (H - 14) / 2, width: midW, height: 14))

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = NSColor(white: 0.7, alpha: 1)
        label.alignment = .center
        label.frame = NSRect(x: midX - 4, y: (H - 14) / 2 - 1, width: midW + 8, height: 14)

        spinner = NSProgressIndicator(frame: NSRect(x: (W - 14) / 2, y: (H - 14) / 2, width: 14, height: 14))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isDisplayedWhenStopped = false

        [xBtn, okBtn, wave, label, spinner].forEach { bg.addSubview($0!) }
    }

    func showPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - W - 18, y: vf.minY + 18))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hidePanel(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.state == .idle else { return }
            self.panel.orderOut(nil)
        }
    }

    func say(_ text: String) {
        wave.isHidden = true
        spinner.stopAnimation(nil)
        label.stringValue = text
        label.isHidden = false
    }

    // MARK: 操作

    func toggle() {
        zlog("合図を受信 state=\(state)")
        switch state {
        case .idle: startRecording()
        case .recording: finish()
        case .busy: break
        }
    }

    func startRecording() {
        zlog("マイク許可=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)（0未確認 1制限 2拒否 3許可）")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { if ok { self.startRecording() } }
            }
            return
        case .denied, .restricted:
            showError("マイク不可")
            return
        default: break
        }

        let rec = Recorder()
        rec.onLevel = { [weak self] l in self?.wave.push(l) }
        do { try rec.start() } catch { zlog("録音開始に失敗: \(error)"); showError("マイク不可"); return }
        zlog("録音開始")
        recorder = rec
        state = .recording
        wave.reset(); wave.isHidden = false
        label.isHidden = true
        spinner.stopAnimation(nil)
        okBtn.enabled = true; xBtn.enabled = true
        showPanel()
        autoStop = Timer.scheduledTimer(withTimeInterval: maxRecordSeconds, repeats: false) { [weak self] _ in self?.finish() }
    }

    func cancel() {
        guard state == .recording else { return }
        autoStop?.invalidate()
        recorder?.discard(); recorder = nil
        state = .idle
        hidePanel()
    }

    func finish() {
        guard state == .recording, let rec = recorder else { return }
        autoStop?.invalidate()
        rec.stop(); recorder = nil
        zlog("録音停止 最大音量=\(String(format: "%.2f", rec.peak))（0.05未満なら無音）")
        state = .busy
        okBtn.enabled = false; xBtn.enabled = false
        wave.isHidden = true; label.isHidden = true
        spinner.startAnimation(nil)

        let url = rec.url
        Task {
            let text = await self.process(url)
            try? FileManager.default.removeItem(at: url)
            await MainActor.run { self.deliver(text) }
        }
    }

    func process(_ url: URL) async -> String? {
        let data = (try? Data(contentsOf: url)) ?? Data()
        zlog("録音サイズ \(data.count) bytes（約\(data.count / 32000)秒）")
        guard data.count > 8000 else { return nil } // 約0.25秒未満は無音扱い
        let dict = loadDict()
        guard let t = await post("/api/transcribe", ["audio": data.base64EncodedString(), "dict": dict]),
              (t["ok"] as? Bool) == true,
              let raw = (t["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { zlog("文字起こし失敗"); return nil }
        zlog("文字起こし: \(raw.prefix(40))")
        if let p = await post("/api/polish", ["text": raw, "style": "clean", "dict": dict]),
           (p["ok"] as? Bool) == true, let out = p["text"] as? String, !out.isEmpty {
            return out
        }
        return raw
    }

    func deliver(_ text: String?) {
        state = .idle
        guard let text = text else { showError("聞き取れず"); return }
        zlog("完成 \(text.count)文字 / 貼り付け許可=\(AXIsProcessTrusted())")
        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        if AXIsProcessTrusted() {
            pasteCmdV()
            say("✓")
            hidePanel(after: 0.5)
            // 貼り付け先が読み終わるのを待ってから、もともとコピーしていたものに戻す。
            // その間に別の物がコピーされていたら（changeCount が変わったら）戻さない
            let mark = pb.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard pb.changeCount == mark else { return }
                self.restorePasteboard(pb, saved)
            }
        } else {
            say("コピー済み ⌘V")
            hidePanel(after: 1.6)
        }
    }

    // クリップボードの中身を種類ごとまるごと控える（文字・画像・ファイルなど）
    func snapshotPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var m: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { m[t] = d } }
            return m
        }
    }

    func restorePasteboard(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        if saved.isEmpty { return }
        let items: [NSPasteboardItem] = saved.map { m in
            let it = NSPasteboardItem()
            for (t, d) in m { it.setData(d, forType: t) }
            return it
        }
        pb.writeObjects(items)
    }

    func showError(_ msg: String) {
        state = .idle
        showPanel()
        say(msg)
        hidePanel(after: 1.4)
    }

    func pasteCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) // 9 = V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let u = URL(string: API + path) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        // workers.dev は一部のUAを弾くのでブラウザ相当のUAを名乗る
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ZukiVoice/1.0", forHTTPHeaderField: "User-Agent")
        if let k = appKey() { req.setValue(k, forHTTPHeaderField: "x-app-key") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, resp) = try? await URLSession.shared.data(for: req) else { zlog("通信失敗 \(path)"); return nil }
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
            zlog("サーバーが断った \(path) status=\(code)（401なら合言葉が合っていない）")
        }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
