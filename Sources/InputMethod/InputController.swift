import AppKit
import InputMethodKit

enum RimeData {
    static var shared: URL { Bundle.main.resourceURL!.appendingPathComponent("Rime", isDirectory: true) }
    static var user: URL { LocalPaths.rime }
    // Shipped alongside the schema; read to spell out the user's own words.
    static var pinyinDictionary: URL { shared.appendingPathComponent("luna_pinyin.dict.yaml") }
}

@objc(LocalInputController)
final class LocalInputController: IMKInputController {
    private let engine = LIRime()
    private let panel = CandidatePanel()
    private var english = false
    private var hasMarkedText = false
    private var shiftTap = ShiftTapTracker()
    private var voicePress = VoicePressTracker()
    private var voiceGuard = VoiceCommitGuard()
    private var voiceID: UUID?
    private var voiceReply: VoiceReply?
    private var lastRemoteReply: VoiceReply?
    private var voiceTimer: Timer?
    private var voiceReplyObserver: NSObjectProtocol?
    private var originPID: pid_t?
    private var voiceComposition: VoiceComposition?
    private var correctionUndo: VoiceCorrectionUndo?
    private var voiceStarted = Date()
    private var activeVoiceShortcut: VoiceShortcut?
    private var active = false
    private var jevTask: Task<Void, Never>?
    private var jevGeneration = UUID()
    private var jevOrder: JevCandidateOrder?
    private var jevPool: [String] = []
    private var jevStatus = ""
    private var manualCandidates = false
    private var previousRaw = ""
    private static weak var activeController: LocalInputController?
    private static var companionPrepared = false

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.activeController?.cancelJev()
        Self.activeController?.panel.orderOut(nil)
        Self.activeController = self
        active = true
        if !Self.companionPrepared {
            Self.companionPrepared = true
            launchCompanion(activate: false) { error in
                if error != nil { Self.companionPrepared = false }
            }
        }
        shiftTap.reset()
        voicePress.reset()
        // The word list is edited in the companion app; pick up changes here
        // rather than polling, and replace sessions built from the old table.
        if RimeCustomPhrases.sync(vocabulary: Settings.load().voiceVocabulary,
                                  dictionaryAt: RimeData.pinyinDictionary, userDirectory: RimeData.user) {
            LIRime.invalidateSessions()
        }
        if !engine.open() {
            panel.show(title: "拼音词库未就绪", detail: "英文仍可输入 · 请重新运行安装包构建", anchor: anchor())
        }
    }
    override func deactivateServer(_ sender: Any!) {
        correctionUndo = nil
        commitComposition(sender)
        cancelVoice()
        panel.orderOut(nil)
        shiftTap.reset()
        active = false
        voicePress.reset()
        if Self.activeController === self { Self.activeController = nil }
        super.deactivateServer(sender)
    }
    override func inputControllerWillClose() {
        cancelJev()
        cancelVoice()
        panel.orderOut(nil)
        super.inputControllerWillClose()
    }
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.keyUp.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue |
            NSEvent.EventTypeMask.leftMouseDown.rawValue | NSEvent.EventTypeMask.rightMouseDown.rawValue)
    }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown || event.type == .leftMouseDown || event.type == .rightMouseDown {
            let undo = correctionUndo
            correctionUndo = nil
            if undo != nil { panel.orderOut(nil) }
            if event.type == .keyDown, event.keyCode == 53, flags.intersection([.command, .control, .option, .shift]).isEmpty,
               let undo, active, Self.activeController === self,
               originPID == NSWorkspace.shared.frontmostApplication?.processIdentifier, let destination = client(),
               let range = undo.replacementRange(in: IMKVoiceTextClient(client: destination)) {
                destination.insertText(undo.original, replacementRange: range)
                return true
            }
            // Once speech has finished, typing accepts its raw text and cancels the pending AI task.
            if voiceReply?.phase == "correcting", voicePress.held == nil,
               !(event.type == .keyDown && event.keyCode == 53) {
                if let reply = voiceReply {
                    voiceReply = VoiceReply(phase: "ready", text: reply.originalText ?? reply.text)
                }
                commitVoice()
            }
        }
        let shortcut = activeVoiceShortcut ?? Settings.load().voiceShortcut
        if event.type == .keyDown, event.keyCode == 53, voiceID != nil {
            cancelVoice(); return true
        }
        let action = voicePress.update(type: event.type, keyCode: event.keyCode,
            flags: event.modifierFlags, isRepeat: event.type == .keyDown && event.isARepeat, binding: shortcut)
        switch action {
        case .start: startVoice(shortcut)
        case .stop: stopVoice()
        case .cancel: cancelVoice()
        case .none: break
        }
        if event.type == .keyUp {
            return action == .stop || (voiceID != nil && !shortcut.isModifier && event.keyCode == shortcut.keyCode)
        }
        if event.type == .flagsChanged {
            if shortcut.isModifier && event.keyCode == shortcut.keyCode {
                shiftTap.reset()
                return false
            }
            let other = !flags.intersection([.command, .control, .option, .capsLock, .function]).isEmpty
            if shiftTap.update(shift: flags.contains(.shift), otherModifier: other, time: event.timestamp),
               Settings.load().shiftToggle, voiceID == nil {
                switchTypingMode()
            }
            return false
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            voicePress.reset()
            commitComposition(sender)
            cancelVoice()
            return false
        }
        guard event.type == .keyDown else { return false }
        shiftTap.keyDown()
        // Only consume the exact dictation chord; preserve all other app shortcuts.
        if shortcut.matches(keyCode: event.keyCode, flags: flags) {
            return true
        }
        if !flags.intersection([.command, .control, .option]).isEmpty {
            commitComposition(sender)
            if voiceID != nil { cancelVoice() }
            return false
        }
        if voiceID != nil {
            cancelVoice()
            if event.keyCode == 53 { return true }
        }
        if english || flags.contains(.capsLock) {
            if hasMarkedText { commitComposition(sender) }
            return false
        }
        let special: [UInt16: Int32] = [36: 0xff0d, 76: 0xff0d, 48: 0xff09, 51: 0xff08,
            53: 0xff1b, 117: 0xffff, 123: 0xff51, 124: 0xff53, 125: 0xff54,
            126: 0xff52, 115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56]
        let key: Int32
        if let code = special[event.keyCode] { key = code }
        else if let chars = event.characters, chars.unicodeScalars.count == 1,
                let scalar = chars.unicodeScalars.first, scalar.value < 128 { key = Int32(scalar.value) }
        else { commitComposition(sender); return false }
        if let order = jevOrder {
            if flags.intersection([.shift]).isEmpty, [45, 61, 0xff55, 0xff56].contains(key) {
                let offset = [45, 0xff55].contains(key) ? -1 : 1
                cancelJev(clearOrder: false)
                manualCandidates = true
                if jevOrder?.turnPage(offset) == true {
                    showCandidates(engine.snapshot())
                    return true
                }
                // The ranked pool is a permutation of the first 20 native items.
                // Resume beyond it without duplicating or skipping any candidates.
                let nativePage = engine.snapshot()["page"] as? Int ?? 0
                if nativePage < order.page {
                    for _ in nativePage..<order.page { _ = engine.process(0xff56, modifiers: 0) }
                }
                if engine.snapshot()["lastPage"] as? Bool == true {
                    showCandidates(engine.snapshot())
                    return true
                }
                cancelJev()
            }
            if flags.intersection([.shift]).isEmpty, key == 0xff52 || key == 0xff54 {
                cancelJev(clearOrder: false)
                manualCandidates = true
                jevOrder?.move(key == 0xff52 ? -1 : 1)
                showCandidates(engine.snapshot())
                return true
            }
            let row = key == 32 ? order.selected : Int(key - 49)
            if flags.intersection([.shift]).isEmpty, key == 32 || (49...53).contains(key), let index = order.engineIndex(for: row) {
                cancelJev()
                engine.selectGlobal(UInt(index))
                refresh()
                return true
            }
            // Rime implicitly accepts its highlight before punctuation. Accept the
            // visible highlight first so punctuation cannot commit a different word.
            if let scalar = UnicodeScalar(UInt32(max(0, key))),
               CharacterSet.punctuationCharacters.contains(scalar), ![39, 45].contains(key),
               let index = order.engineIndex(for: order.selected) {
                cancelJev()
                engine.selectGlobal(UInt(index))
                refresh()
            }
        }
        cancelJev()
        if [0xff52, 0xff54, 0xff55, 0xff56, 45, 61, 0xff09].contains(key) { manualCandidates = true }
        let consumed = engine.process(key, modifiers: flags.contains(.shift) ? 1 : 0)
        refresh()
        return consumed
    }

    private func refresh() {
        cancelJev()
        let commit = engine.takeCommit()
        if !commit.isEmpty { client()?.insertText(commit, replacementRange: replacement); hasMarkedText = false }
        let snapshot = engine.snapshot()
        let preedit = snapshot["preedit"] as? String ?? ""
        if !preedit.isEmpty || hasMarkedText {
            let caret = snapshot["caret"] as? Int ?? preedit.utf16.count
            client()?.setMarkedText(preedit, selectionRange: NSRange(location: caret, length: 0), replacementRange: replacement)
        }
        hasMarkedText = !preedit.isEmpty
        let raw = engine.rawInput()
        if raw != previousRaw { manualCandidates = false; previousRaw = raw }
        guard !preedit.isEmpty else { panel.orderOut(nil); return }
        scheduleJev(snapshot)
        showCandidates(snapshot)
    }
    private func showCandidates(_ snapshot: [AnyHashable: Any]) {
        let preedit = snapshot["preedit"] as? String ?? ""
        let choices = jevOrder.map { order in order.indices.map { jevPool[$0] } }
            ?? (snapshot["candidates"] as? [String] ?? [])
        panel.onSelect = { [weak self] index in
            guard let self, self.active else { return }
            let global = self.jevOrder?.engineIndex(for: index)
            self.cancelJev()
            if let global { self.engine.selectGlobal(UInt(global)) }
            else { self.engine.select(UInt(index)) }
            self.refresh()
        }
        panel.show(title: preedit, candidates: choices, selected: jevOrder?.selected ?? (snapshot["highlight"] as? Int ?? 0),
            scores: jevOrder?.scores,
            partialRows: jevOrder?.partialRows(inputLength: engine.rawInput().utf8.count) ?? [],
            detail: (jevOrder.map { "完整匹配优先 · Jev 第 \($0.page + 1)/\($0.pageCount) 页 · " } ?? (jevStatus.isEmpty ? "中 · " : "\(jevStatus) · ")) +
                "数字选词  ↑↓ 选择  − / = 翻页  Shift 英文", anchor: anchor())
    }
    private func cancelJev(clearOrder: Bool = true) {
        jevGeneration = UUID()
        jevTask?.cancel(); jevTask = nil
        if clearOrder { jevOrder = nil; jevPool = []; jevStatus = "" }
    }
    private func precedingText(_ destination: IMKTextInput) -> String? {
        let marked = destination.markedRange()
        let selection = destination.selectedRange()
        let end = marked.location != NSNotFound ? marked.location : selection.location
        guard end != NSNotFound, end >= 0 else { return nil }
        if end == 0 { return "" }
        let range = NSRange(location: max(0, end - 128), length: min(128, end))
        return destination.attributedSubstring(from: range)?.string
    }
    private func scheduleJev(_ snapshot: [AnyHashable: Any]) {
        guard active, Settings.load().jevEnabled else { return }
        guard !manualCandidates, snapshot["page"] as? Int == 0 else {
            jevStatus = "Jev 暂停 · 手动选词"; return
        }
        guard let destination = client(), let prefix = precedingText(destination) else {
            jevStatus = "Jev 未评分 · 此输入框不支持读取上下文"; return
        }
        let key = JevCredential.load()
        guard !key.isEmpty else { jevStatus = "Jev 未评分 · 请配置 Key"; return }
        let details = engine.candidateDetails(20)
        let pool = details.compactMap { $0["text"] as? String }
        let coverageEnds = details.compactMap { $0["coverageEnd"] as? Int }
        guard !details.isEmpty, pool.count == details.count, coverageEnds.count == details.count else {
            jevStatus = "Jev 未评分 · 当前拼音覆盖范围不可确认"; return
        }
        guard pool.count > 1 else { jevStatus = "Jev · 当前候选不足两项"; return }
        jevStatus = prefix.isEmpty ? "Jev 评分中 · 暂无前文" : "Jev 评分中…"
        let context = JevContext(precedingText: prefix, pinyin: engine.rawInput(),
                                 preedit: snapshot["preedit"] as? String ?? "", candidates: pool, coverageEnds: coverageEnds)
        let generation = jevGeneration
        let identity = ObjectIdentifier(destination as AnyObject)
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let marked = destination.markedRange(), selection = destination.selectedRange()
        let pageSize = (snapshot["candidates"] as? [String])?.count ?? 5
        jevTask = Task { @MainActor [weak self] in
            let isCurrent = { [weak self] in
                guard let self, self.active, Self.activeController === self,
                      self.jevGeneration == generation, !self.manualCandidates,
                      Settings.load().jevEnabled, JevCredential.load() == key,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let current = self.client(), ObjectIdentifier(current as AnyObject) == identity,
                      current.markedRange() == marked, current.selectedRange() == selection,
                      self.precedingText(current) == prefix, self.engine.rawInput() == context.pinyin,
                      NSDictionary(dictionary: self.engine.snapshot()).isEqual(to: snapshot) else { return false }
                return self.engine.candidatePool(20) == pool
            }
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                try Task.checkCancellation()
                guard isCurrent() else { return }
                let ranking = try await JevClient.shared.rank(context: context, apiKey: key)
                try Task.checkCancellation()
                guard let self, isCurrent() else { return }
                self.jevPool = pool
                self.jevOrder = JevCandidateOrder(ranking: ranking, pageSize: pageSize)
                self.showCandidates(snapshot)
            } catch {
                // No retries on the keystroke path. Keep Rime immediately usable.
                guard !Task.isCancelled, let self, isCurrent() else { return }
                if let serviceError = error as? JevError, case .service(let code) = serviceError {
                    self.jevStatus = "Jev HTTP \(code) · 使用本地候选"
                } else if (error as? URLError)?.code == .timedOut {
                    self.jevStatus = "Jev 超时 · 使用本地候选"
                } else { self.jevStatus = "Jev 暂不可用 · 使用本地候选" }
                self.showCandidates(snapshot)
            }
        }
    }
    private var replacement: NSRange { NSRange(location: NSNotFound, length: NSNotFound) }
    override func commitComposition(_ sender: Any!) {
        let selected = jevOrder.flatMap { $0.engineIndex(for: $0.selected) }
        cancelJev()
        if let selected { engine.selectGlobal(UInt(selected)) }
        if !engine.rawInput().isEmpty {
            engine.commit()
            refresh()
        } else if selected != nil { refresh() }
    }
    override func hidePalettes() { cancelJev(); panel.orderOut(nil) }
    private func anchor() -> NSRect {
        var rect = NSRect.zero
        if let c = client() { _ = c.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect) }
        if rect.width == 0 && rect.height == 0 {
            let p = NSEvent.mouseLocation
            return NSRect(x: p.x, y: p.y, width: 1, height: 20)
        }
        return rect
    }
    override func menu() -> NSMenu! {
        let menu = NSMenu()
        menu.addItem(withTitle: english ? "切换到中文" : "切换到英文", action: #selector(toggleMode(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "轻言设置与语音状态…", action: #selector(openSettings(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "语音快捷键：\(Settings.load().voiceShortcut.displayName)", action: nil, keyEquivalent: "")
        menu.addItem(hint)
        return menu
    }
    private func switchTypingMode() {
        cancelJev()
        if !english {
            let raw = engine.takeRawInput()
            // Clear engine/IME state before insertText, which can reenter the controller.
            english = true
            hasMarkedText = false
            panel.orderOut(nil)
            if !raw.isEmpty { client()?.insertText(raw, replacementRange: replacement) }
        } else {
            english = false
            panel.orderOut(nil)
        }
    }
    @objc private func toggleMode(_ sender: Any?) { switchTypingMode() }
    @objc private func openSettings(_ sender: Any?) { launchCompanion(activate: true) }
    private func launchCompanion(activate: Bool, completion: ((Error?) -> Void)? = nil) {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalInput Voice.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion?(error) }
        }
    }

    private func startVoice(_ shortcut: VoiceShortcut) {
        // Starting a fresh press supersedes an unfinished transcription.
        if voiceID != nil { cancelVoice(resetPress: false) }
        commitComposition(nil)
        let id = UUID()
        voiceID = id
        activeVoiceShortcut = shortcut
        voiceGuard.begin(id)
        let generation = voiceGuard.generation
        voiceStarted = Date()
        originPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let destination = client() else { cancelVoice(); return }
        voiceComposition = VoiceComposition(client: IMKVoiceTextClient(client: destination))
        voiceReply = VoiceReply(phase: "starting")
        lastRemoteReply = nil
        do {
            try LocalPaths.prepare()
            try renewVoiceHold(id)
            try LocalPaths.write(VoiceRequest(id: id, language: Settings.load().language, created: Date(), heldShortcut: shortcut), to: LocalPaths.file(id, "request"))
        } catch { cancelVoice(); return }
        showVoice()
        launchCompanion(activate: false) { [weak self] error in
            guard let self, self.voiceGuard.accepts(id, generation: generation) else { return }
            if let error {
                self.voiceReply = VoiceReply(phase: "error", detail: error.localizedDescription)
                self.showVoice()
            } else {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("org.localinput.voice.start"), object: id.uuidString, userInfo: nil, deliverImmediately: true)
            }
        }
        voiceReplyObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("org.localinput.voice.reply"), object: id.uuidString, queue: .main) { [weak self] _ in
                self?.pollVoice(id, generation: generation)
            }
        voiceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.pollVoice(id, generation: generation)
        }
    }
    private func pollVoice(_ id: UUID, generation: Int) {
        guard self.voiceGuard.accepts(id, generation: generation) else { return }
        guard self.active, Self.activeController === self,
              self.originPID == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let destination = self.client(),
              self.voiceComposition?.matches(IMKVoiceTextClient(client: destination)) == true else {
            self.cancelVoice(); return
        }
        // Only IMK key-up / modifier events change the held state. Session-wide
        // CGEventSource snapshots are not reliable evidence that this key was released.
        if self.voicePress.held != nil {
            do { try self.renewVoiceHold(id) }
            catch { self.cancelVoice(); return }
        }
        guard self.voiceID == id else { return }
        if let reply = LocalPaths.read(VoiceReply.self, from: LocalPaths.file(id, "reply")), reply != self.lastRemoteReply {
            self.lastRemoteReply = reply; self.voiceReply = reply
            if reply.phase == "cancelled" { self.cancelVoice(); return }
            if ["recording", "transcribing", "correcting", "ready"].contains(reply.phase), !reply.text.isEmpty {
                guard self.voiceComposition?.update(reply.text, client: IMKVoiceTextClient(client: destination)) == true else {
                    self.cancelVoice(); return
                }
            }
            if reply.phase == "error" {
                self.cancelVoice()
                self.panel.show(title: "语音暂不可用", detail: reply.detail, anchor: self.anchor())
                return
            }
            if reply.phase == "ready", self.voicePress.held == nil { self.commitVoice(); return }
            self.showVoice()
        }
        if Date().timeIntervalSince(self.voiceStarted) > 180 {
            self.cancelVoice()
            self.panel.show(title: "语音处理超时", detail: "可继续打字，或打开轻言设置检查模型", anchor: self.anchor())
        }
    }
    private func showVoice() {
        guard let reply = voiceReply else { return }
        panel.onSelect = nil
        let title: String
        let detail: String
        switch reply.phase {
        case "starting": title = "正在准备麦克风…"; detail = "Esc 取消 · 首次使用请先在轻言设置中授权"
        case "recording":
            title = voiceComposition?.canPreview == false && !reply.text.isEmpty ? reply.text : "正在聆听 · 文字实时更新"
            detail = voiceComposition?.canPreview == false ? "此输入框暂不支持内嵌预览 · 松开输入 · Esc 取消" :
                "松开 \((activeVoiceShortcut ?? Settings.load().voiceShortcut).displayName) 定稿 · Esc 取消 · 最长 60 秒"
        case "correcting": title = "正在本地轻度纠错…"; detail = "开始打字保留原文 · Esc 取消"
        case "transcribing": title = "正在完成语音识别…"; detail = "录音不会上传 · Esc 取消"
        case "ready": title = reply.text; detail = "松开快捷键自动输入 · Esc 取消"
        case "error": title = "语音暂不可用"; detail = reply.detail + " · Esc 返回"
        default: title = "语音已取消"; detail = "Esc 返回打字"
        }
        panel.show(title: title, detail: detail, anchor: anchor())
    }
    private func renewVoiceHold(_ id: UUID) throws {
        try LocalPaths.write(VoiceHoldLease(id: id, renewedAt: Date()), to: LocalPaths.file(id, "hold"))
    }
    private func stopVoice() {
        guard let id = voiceID else { return }
        if voiceReply?.phase == "ready" { commitVoice(); return }
        do {
            try LocalPaths.write(VoiceCommand(action: "stop"), to: LocalPaths.file(id, "command"))
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("org.localinput.voice.command"), object: id.uuidString, userInfo: nil, deliverImmediately: true)
        } catch { cancelVoice() }
    }
    private func commitVoice() {
        guard let id = voiceID, let reply = voiceReply, reply.phase == "ready",
              voiceGuard.accepts(id, generation: voiceGuard.generation), active, Self.activeController === self,
              originPID == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let destination = client(), let composition = voiceComposition,
              composition.matches(IMKVoiceTextClient(client: destination)) else { cancelVoice(); return }
        let text = reply.text
        let adapter = IMKVoiceTextClient(client: destination)
        let marked = adapter.voiceMarkedRange
        let start = marked.location != NSNotFound && marked.length > 0 && marked.length != NSNotFound ? marked.location : adapter.voiceSelection.location
        let original = reply.originalText
        // Detach and invalidate the async session before the native client call.
        voiceComposition = nil
        cancelVoice()
        if composition.commit(text, client: adapter), let original, original != text, start != NSNotFound {
            let undo = VoiceCorrectionUndo(original: original, corrected: text,
                range: NSRange(location: start, length: text.utf16.count), created: Date())
            if undo.replacementRange(in: adapter) != nil {
                correctionUndo = undo
                panel.show(title: "已轻度纠错", detail: "立即按 Esc 恢复原文 · 继续输入后可在轻言设置中复制原文", anchor: anchor())
            }
        }
    }
    private func cancelVoice(resetPress: Bool = true) {
        if resetPress { voicePress.reset(); shiftTap.reset() }
        voiceTimer?.invalidate(); voiceTimer = nil
        if let observer = voiceReplyObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            voiceReplyObserver = nil
        }
        if let id = voiceID {
            try? LocalPaths.write(VoiceCommand(action: "cancel"), to: LocalPaths.file(id, "command"))
            // Let the companion observe cancellation, then erase the IPC transcript.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { LocalPaths.remove(id) }
        }
        let composition = voiceComposition
        voiceComposition = nil
        voiceGuard.invalidate()
        voiceID = nil; voiceReply = nil; lastRemoteReply = nil
        activeVoiceShortcut = nil
        if let destination = client() { composition?.cancel(client: IMKVoiceTextClient(client: destination)) }
        panel.orderOut(nil)
    }
}
