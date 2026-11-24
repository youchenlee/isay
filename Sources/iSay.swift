import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

@main
@MainActor
final class ISay: NSObject, NSApplicationDelegate {
    private struct Capture {
        let recorder: AVAudioRecorder
        let folder: URL
        let target: PasteTarget?
        let deadline: TimeInterval
        let context: String
    }

    private struct CorrectionWatch {
        let text: String
        let target: PasteTarget
        let start: Int
        var polls = 0
        var lastSeen: String?
    }

    private enum State { case idle, recording(Capture), recognizing(URL) }
    private enum RecordingEnd { case release, limit, cancel }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var feedback = DictationFeedback()
    private let statusLine = NSMenuItem(title: "正在啟動…", action: nil, keyEquivalent: "")
    private let hintLine = NSMenuItem(title: "提示詞：尚未送出", action: nil, keyEquivalent: "")
    private let copyLine = NSMenuItem(title: "複製上次辨識文字", action: #selector(copyTranscript), keyEquivalent: "")
    private let loginLine = NSMenuItem(title: "登入時啟動", action: #selector(toggleLogin), keyEquivalent: "")
    private let contextLine = NSMenuItem(title: "參考游標前文字", action: #selector(toggleContext), keyEquivalent: "")
    private let learnLine = NSMenuItem(title: "", action: #selector(addSuggestion), keyEquivalent: "")
    private var correctionWatch: CorrectionWatch?
    private var correctionTimer: Timer?
    private var suggestion: LearnedCorrection?
    private static let contextKey = "useCursorContext"
    private var usesContext: Bool { UserDefaults.standard.object(forKey: Self.contextKey) as? Bool ?? true }
    private var lastTranscript: String?
    private var mayType = false
    private var pendingInput: (String, PasteTarget)?
    private let tools = Transcriber(
        directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/isay"),
        whisper: executable("whisper-cli"), openCC: executable("opencc")
    )
    private var state = State.idle
    private var gesture = PushToTalk()
    private var tap: CFMachPort?
    private var permissionTimer: Timer?
    private var startTimer: Timer?
    private var recordingTimer: Timer?

    static func main() {
        let app = NSApplication.shared
        let delegate = ISay()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(hintLine)
        menu.addItem(withTitle: "編輯詞庫…", action: #selector(editVocabulary), keyEquivalent: "").target = self
        contextLine.target = self
        contextLine.state = usesContext ? .on : .off
        menu.addItem(contextLine)
        learnLine.target = self
        learnLine.isHidden = true
        menu.addItem(learnLine)
        copyLine.target = self
        copyLine.isHidden = true
        menu.addItem(copyLine)
        loginLine.target = self
        menu.addItem(loginLine)
        refreshLoginItem()
        menu.addItem(withTitle: "設定權限…", action: #selector(setUpPermissions), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 iSay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        statusItem.menu = menu
        if let button = statusItem.button {
            button.setAccessibilityLabel("iSay 語音輸入")
        }
        removeStaleRecordings()
        refreshPermissions()
    }

    /// 清掉上次異常結束時留下的錄音與逐字稿。只處理 iSay 建立的 `isay-<UUID>` 資料夾與已知檔名。
    private func removeStaleRecordings() {
        let files = FileManager.default
        let temp = files.temporaryDirectory
        guard let names = try? files.contentsOfDirectory(atPath: temp.path) else { return }
        for name in names where name.hasPrefix("isay-") && UUID(uuidString: String(name.dropFirst(5))) != nil {
            let folder = temp.appendingPathComponent(name, isDirectory: true)
            guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            for file in ["speech.wav", "whisper.txt", "traditional.txt"] {
                try? files.removeItem(at: folder.appendingPathComponent(file))
            }
            if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? files.removeItem(at: folder)
            }
        }
    }

    private func refreshLoginItem() {
        switch SMAppService.mainApp.status {
        case .enabled: loginLine.state = .on
        case .requiresApproval: loginLine.state = .mixed
        default: loginLine.state = .off
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            show("無法變更登入時啟動：\(error.localizedDescription)", icon: "exclamationmark.circle")
        }
        refreshLoginItem()
        if SMAppService.mainApp.status == .requiresApproval {
            show("請在系統設定的「登入項目」允許 iSay")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        switch state {
        case .idle: break
        case .recording: endRecording(.cancel)
        case let .recognizing(folder): try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func executable(_ name: String) -> URL {
        #if arch(arm64)
        let prefix = "/opt/homebrew"
        #else
        let prefix = "/usr/local"
        #endif
        return URL(fileURLWithPath: "\(prefix)/bin/\(name)")
    }

    private func show(_ text: String, icon: String = "mic") {
        statusLine.title = text
        statusItem.button?.toolTip = "iSay：\(text)"
        statusItem.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
    }

    private func refreshPermissions() {
        guard tools.isReady else { show("缺少語音模型或工具，請重新執行 setup.sh", icon: "exclamationmark.circle"); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            show("請先在「設定權限」開啟麥克風", icon: "mic.slash")
            return
        }
        guard AXIsProcessTrusted() else { show("請先在「設定權限」開啟輔助使用", icon: "mic.slash"); return }
        if tap == nil { installKeyboardTap() }
        guard tap != nil else { show("無法監聽右 ⌘，請檢查輸入監控權限", icon: "mic.slash"); return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        if case .idle = state { show("按住右 ⌘ 說話，放開貼上") }
    }

    @objc private func setUpPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        case .denied, .restricted:
            openPrivacy("Privacy_Microphone")
        case .authorized:
            if !AXIsProcessTrusted() {
                openPrivacy("Privacy_Accessibility")
            } else if tap == nil, !CGPreflightListenEventAccess() {
                openPrivacy("Privacy_ListenEvent")
            }
        @unknown default: break
        }
        refreshPermissions()
        if tap == nil, permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            }
        }
    }

    private func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func editVocabulary() {
        do {
            try FileManager.default.createDirectory(at: tools.directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: tools.vocabularyFile.path) {
                try Vocabulary.starter.write(to: tools.vocabularyFile, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(tools.vocabularyFile)
        } catch {
            show("打不開詞庫：\(error.localizedDescription)", icon: "exclamationmark.circle")
        }
    }

    private func installKeyboardTap() {
        let events: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    let app = Unmanaged<ISay>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { app.handle(type, event) }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        let action: PushToTalk.Action
        let isEscape = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53
        let releasedRightCommand = type == .flagsChanged
            && event.getIntegerValueField(.keyboardEventKeycode) == 54
            && event.flags.rawValue & 0x10 == 0
        if type != .keyUp && !releasedRightCommand { mayType = false }
        if pendingInput != nil && type != .keyUp {
            if releasedRightCommand {
                DispatchQueue.main.async { [weak self] in self?.sendPendingInput() }
            } else {
                pendingInput = nil
                show("已略過自動輸入，可從選單複製上次辨識文字")
                feedback.show("已略過自動輸入", duration: 2)
            }
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            action = gesture.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            action = gesture.modifiers(key: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        case .keyDown:
            action = gesture.keyDown(event.getIntegerValueField(.keyboardEventKeycode))
        case .keyUp:
            gesture.keyUp(event.getIntegerValueField(.keyboardEventKeycode))
            return
        default:
            action = gesture.cancel()
        }
        guard action != .none else { return }
        DispatchQueue.main.async { [weak self] in self?.apply(action, isEscape: isEscape) }
    }

    private func apply(_ action: PushToTalk.Action, isEscape: Bool) {
        let wasStarting = startTimer != nil
        startTimer?.invalidate()
        startTimer = nil
        switch action {
        case .none: break
        case .start:
            guard case .idle = state else { return }
            stopWatchingCorrections()
            let target = PasteTarget.current()
            guard target?.isSecure != true else {
                show("密碼欄位不開啟錄音", icon: "mic.slash")
                return
            }
            let context = usesContext ? target?.textBeforeCursor(limit: 80) ?? "" : ""
            startTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.startRecording(target: target, context: context) }
            }
        case .finish: endRecording(.release)
        case .cancel:
            if case .recording = state {
                endRecording(.cancel)
                if isEscape { show("已取消錄音"); feedback.show("已取消錄音", duration: 1.2) }
            } else if wasStarting && isEscape {
                show("已取消錄音")
                feedback.show("已取消錄音", duration: 1.2)
            }
        }
    }

    private func startRecording(target: PasteTarget?, context: String) {
        guard case .idle = state else { return }
        guard target?.stillFocused() != false else {
            show("輸入位置已改變，請再按右 ⌘", icon: "mic.slash")
            return
        }
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("isay-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let recorder = try AVAudioRecorder(url: folder.appendingPathComponent("speech.wav"), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
            ])
            let limit: TimeInterval = 60
            let deadline = ProcessInfo.processInfo.systemUptime + limit
            guard recorder.record(forDuration: limit) else { throw SpeechError(message: "無法錄音，請確認麥克風。") }
            state = .recording(Capture(recorder: recorder, folder: folder, target: target, deadline: deadline, context: context))
            show("正在錄音，放開右 ⌘ 辨識，Esc 取消", icon: "mic.fill")
            feedback.show("正在錄音 · 放開右 ⌘ · Esc 取消")
            recordingTimer = Timer.scheduledTimer(withTimeInterval: limit, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.endRecording(.limit)
                }
            }
        } catch {
            try? files.removeItem(at: folder)
            show(error.localizedDescription, icon: "exclamationmark.circle")
            feedback.show("無法錄音 · 請查看 iSay 選單", duration: 2.5)
        }
    }

    private func endRecording(_ reason: RecordingEnd) {
        guard case let .recording(capture) = state else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        let reachedLimit = reason == .limit || ProcessInfo.processInfo.systemUptime >= capture.deadline
        let duration = capture.recorder.currentTime
        capture.recorder.stop()
        guard reason != .cancel, reachedLimit || duration >= 0.2 else {
            state = .idle
            try? FileManager.default.removeItem(at: capture.folder)
            show("按住右 ⌘ 說話，放開貼上")
            feedback.hide()
            return
        }

        state = .recognizing(capture.folder)
        mayType = true
        show(reachedLimit ? "已達 60 秒，正在辨識…" : "正在辨識…", icon: "ellipsis.circle")
        feedback.show(reachedLimit ? "已達 60 秒，正在辨識…" : "正在辨識…")
        let folder = capture.folder
        let audio = capture.recorder.url
        let target = capture.target
        let context = capture.context
        let tools = tools
        let app = self
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try tools.transcribe(audio, context: context) { prompt in
                    DispatchQueue.main.async { app.showPrompt(prompt) }
                }
            }
            try? FileManager.default.removeItem(at: folder)
            DispatchQueue.main.async { app.deliver(result, to: target) }
        }
    }

    private func showPrompt(_ prompt: Vocabulary.Prompt) {
        let details = NSMenu()
        let note = prompt.fitsModel ? "已依 Whisper 長度上限挑選，全部會被讀入" : "未能核對長度，Whisper 可能截掉部分提示詞"
        details.addItem(NSMenuItem(title: note, action: nil, keyEquivalent: ""))
        details.addItem(NSMenuItem(title: "辨識後替換：\(prompt.replacementCount) 條，不佔提示空間", action: nil, keyEquivalent: ""))
        let contextNote = prompt.context.isEmpty ? "未使用游標前文字" : "游標前文字：\(prompt.context.count) 字，只用於這次辨識"
        details.addItem(NSMenuItem(title: contextNote, action: nil, keyEquivalent: ""))
        details.addItem(.separator())
        if prompt.hints.isEmpty {
            details.addItem(NSMenuItem(title: "沒有送出提示詞", action: nil, keyEquivalent: ""))
        } else {
            for hint in prompt.hints {
                details.addItem(NSMenuItem(title: hint, action: nil, keyEquivalent: ""))
            }
        }
        hintLine.title = "上次送出的提示詞：\(prompt.hints.count)／\(prompt.total)"
        hintLine.submenu = details
    }

    private func deliver(_ result: Result<String, Error>, to target: PasteTarget?) {
        state = .idle
        switch result {
        case let .success(text) where !text.isEmpty:
            lastTranscript = text
            copyLine.isHidden = false
            if let target, mayType, CGEventSource.flagsState(.combinedSessionState).rawValue & 0x10 != 0 {
                pendingInput = (text, target)
                show("已辨識，放開右 ⌘ 輸入")
                feedback.show("已辨識 · 放開右 ⌘ 輸入")
            } else {
                insert(text, into: target)
            }
        case .success:
            show("沒有辨識到語音，再按住右 ⌘ 試一次")
            feedback.show("沒有辨識到語音", duration: 2)
        case let .failure(error):
            show(error.localizedDescription, icon: "exclamationmark.circle")
            feedback.show("辨識未完成 · 請查看 iSay 選單", duration: 2.5)
        }
    }

    private func sendPendingInput() {
        guard let (text, target) = pendingInput else { return }
        pendingInput = nil
        insert(text, into: target)
    }

    private func insert(_ text: String, into target: PasteTarget?) {
        let start = target?.selectionLocation()
        switch target?.insert(text, allowKeyboardInput: mayType) ?? .unavailable("錄音開始時找不到原輸入框") {
        case .inserted:
            show("已輸入文字")
            feedback.show("已輸入", duration: 0.9)
            if let target, let start { watchCorrections(of: text, in: target, from: start) }
        case .typed:
            show("已送出文字，未按 Enter")
            feedback.show("已送出文字 · 未按 Enter", duration: 1.2)
            if let target, let start { watchCorrections(of: text, in: target, from: start) }
        case let .unavailable(reason):
            show("\(reason)，可從選單複製上次辨識文字")
            feedback.show("未自動輸入 · 可從選單複製", duration: 2.5)
        case .unconfirmed:
            show("無法確認是否已輸入，請先檢查輸入框")
            feedback.show("請檢查輸入框", duration: 2.5)
        }
    }

    @objc private func copyTranscript() {
        guard let lastTranscript else { return }
        let board = NSPasteboard.general
        board.clearContents()
        if board.setString(lastTranscript, forType: .string) { show("已複製上次辨識文字") }
        else { show("無法複製辨識文字", icon: "exclamationmark.circle") }
    }

    @objc private func toggleContext() {
        UserDefaults.standard.set(!usesContext, forKey: Self.contextKey)
        contextLine.state = usesContext ? .on : .off
    }

    /// 輸入後 60 秒內，每 2 秒讀回剛輸入的那段文字；使用者改過且停手後，提議加入詞庫。
    private func watchCorrections(of text: String, in target: PasteTarget, from start: Int) {
        stopWatchingCorrections()
        correctionWatch = CorrectionWatch(text: text, target: target, start: start)
        correctionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCorrection() }
        }
    }

    private func pollCorrection() {
        guard var watch = correctionWatch else { return stopWatchingCorrections() }
        watch.polls += 1
        guard watch.polls <= 30,
              let edited = watch.target.text(from: watch.start, length: watch.text.utf16.count + 24) else {
            return stopWatchingCorrections()
        }
        if edited.hasPrefix(watch.text) {
            watch.lastSeen = nil
        } else if edited == watch.lastSeen {
            stopWatchingCorrections()
            if let correction = learnedCorrection(original: watch.text, edited: edited) { offer(correction) }
            return
        } else {
            watch.lastSeen = edited
        }
        correctionWatch = watch
    }

    private func stopWatchingCorrections() {
        correctionTimer?.invalidate()
        correctionTimer = nil
        correctionWatch = nil
    }

    private func offer(_ correction: LearnedCorrection) {
        suggestion = correction
        learnLine.title = "加入詞庫：\(correction.rule)"
        learnLine.isHidden = false
        feedback.show("發現修正：\(correction.wrong) → \(correction.right) · 可從選單加入詞庫", duration: 4)
    }

    @objc private func addSuggestion() {
        guard let suggestion else { return }
        self.suggestion = nil
        learnLine.isHidden = true
        let file = tools.vocabularyFile
        do {
            try FileManager.default.createDirectory(at: tools.directory, withIntermediateDirectories: true)
            let existing: String
            do { existing = try String(contentsOf: file, encoding: .utf8) }
            catch CocoaError.fileReadNoSuchFile { existing = "" }
            let present = existing.split(whereSeparator: \.isNewline)
                .contains { $0.trimmingCharacters(in: .whitespaces) == suggestion.rule }
            if !present {
                let addition = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + suggestion.rule + "\n"
                if existing.isEmpty {
                    try (Vocabulary.starter + addition).write(to: file, atomically: true, encoding: .utf8)
                } else {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(addition.utf8))
                }
            }
            show("已加入詞庫：\(suggestion.rule)")
        } catch {
            show("無法寫入詞庫：\(error.localizedDescription)", icon: "exclamationmark.circle")
        }
    }
}
