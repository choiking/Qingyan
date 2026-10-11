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
    private var candidateNavigation = CandidateNavigation()
    private var nativeCandidates: [String] = []
    private var hasMoreCandidates = true
    private var manualCandidates = false
    private var previousRaw = ""
    private var guessID: UUID?
    private var guessObserver: NSObjectProtocol?
    private var guessOrigin: GuessOrigin?
    private var guesses: [String] = []
    private var guessSelected = 0
    private var guessPreview: VoiceComposition?
    private var guessNotice = false
    private var guessSource = ""
    private struct GuessOrigin { let client: ObjectIdentifier; let pid: pid_t; let selection: NSRange; let prefix: String? }
    private static weak var activeController: LocalInputController?
    private static var companionPrepared = false

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.activeController?.cancelJev()
        Self.activeController?.cancelGuess()
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
        cancelGuess()
        commitComposition(sender)
        CandidateLearningStore.shared.flush()
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
        cancelGuess()
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
        if event.type == .keyDown, voiceID == nil {
            let settings = Settings.load()
            if settings.contextGuessEnabled, settings.guessShortcut.matches(keyCode: event.keyCode, flags: flags) {
                if !event.isARepeat { startGuess() }
                return true
            }
        }
        if guessID != nil || guessNotice, event.type == .keyDown || event.type == .leftMouseDown || event.type == .rightMouseDown {
            if event.type == .keyDown, flags.intersection([.command, .control, .option, .shift]).isEmpty,
               let key = ContextGuess.panelKey(event.keyCode) {
                switch key {
                case .dismiss where event.keyCode == 53 || !guesses.isEmpty: cancelGuess(); return true
                case .accept where !guesses.isEmpty && guessStillValid(): acceptGuess(guessSelected); return true
                case .choose(let row) where guesses.indices.contains(row) && guessStillValid(): acceptGuess(row); return true
                case .move(let step) where !guesses.isEmpty && guessStillValid(): moveGuess(step); return true
                default: break
                }
            }
            cancelGuess()
        }
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
        if !nativeCandidates.isEmpty, !flags.contains(.shift) {
            let actions: [Int32: CandidateNavigation.Action] = [
                0xff51: .left, 0xff53: .right, 0xff52: .up, 0xff54: .down,
                45: .previousPage, 61: .nextPage, 0xff55: .previousPage, 0xff56: .nextPage,
                0xff09: .toggle
            ]
            if let action = actions[key] { navigateCandidates(action); return true }
            if key == 32 || key == 0xff0d {
                selectCandidate(at: candidateNavigation.selected)
                return true
            }
            if (49...54).contains(key) {
                if let position = candidateNavigation.numberPosition(Int(key - 48), count: nativeCandidates.count) {
                    selectCandidate(at: position)
                }
                return true
            }
        }
        // Preserve the displayed highlight when Rime accepts a word implicitly
        // before punctuation, or when the host finalizes this composition.
        if !nativeCandidates.isEmpty {
            _ = engine.highlightGlobal(UInt(candidateEngineIndex(candidateNavigation.selected)))
        }
        cancelJev()
        if [0xff52, 0xff54, 0xff55, 0xff56, 45, 61, 0xff09].contains(key) { manualCandidates = true }
        let spelling = engine.rawInput()
        let consumed = engine.process(key, modifiers: flags.contains(.shift) ? 1 : 0)
        refresh(learningSpelling: spelling)
        return consumed
    }

    private func refresh(learningSpelling: String? = nil) {
        cancelJev()
        let commit = engine.takeCommit()
        if !commit.isEmpty {
            if let spelling = learningSpelling, engine.rawInput().isEmpty {
                CandidateLearningStore.shared.record(spelling: spelling, commit: commit)
            }
            client()?.insertText(commit, replacementRange: replacement); hasMarkedText = false
            recordWords(commit, .typed)
        }
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
    private func candidateEngineIndex(_ position: Int) -> Int {
        if let ranking = jevOrder?.ranking, ranking.indices.indices.contains(position) {
            return ranking.indices[position]
        }
        return position
    }
    private func loadCandidates(through position: Int) {
        while hasMoreCandidates && nativeCandidates.count <= position {
            let batch = engine.candidates(from: UInt(nativeCandidates.count), limit: 37)
            nativeCandidates.append(contentsOf: batch.prefix(36))
            hasMoreCandidates = batch.count > 36
        }
    }
    private func navigateCandidates(_ action: CandidateNavigation.Action) {
        cancelJev(clearOrder: false)
        manualCandidates = true
        loadCandidates(through: candidateNavigation.selected + CandidateNavigation.expandedSize)
        candidateNavigation.navigate(action, count: nativeCandidates.count)
        _ = engine.highlightGlobal(UInt(candidateEngineIndex(candidateNavigation.selected)))
        showCandidates(engine.snapshot())
    }
    private func selectCandidate(at position: Int) {
        guard nativeCandidates.indices.contains(position) else { return }
        let index = candidateEngineIndex(position)
        let spelling = engine.rawInput()
        cancelJev()
        engine.selectGlobal(UInt(index))
        refresh(learningSpelling: spelling)
    }
    private func showCandidates(_ snapshot: [AnyHashable: Any]) {
        loadCandidates(through: candidateNavigation.start + candidateNavigation.capacity - 1)
        let range = candidateNavigation.visibleRange(count: nativeCandidates.count)
        let inputLength = engine.rawInput().utf8.count
        let items = range.map { position -> CandidateGridItem in
            let index = candidateEngineIndex(position)
            let ranking = jevOrder?.ranking
            let score = ranking.flatMap { $0.scores.indices.contains(index) ? $0.scores[index] : nil }
            let partial = ranking?.coverageEnds.map { $0.indices.contains(index) && $0[index] < inputLength } ?? false
            let number = position / 6 == candidateNavigation.selected / 6 ? position % 6 + 1 : nil
            return CandidateGridItem(text: nativeCandidates[index], number: number,
                                     score: score, partial: partial)
        }
        panel.onSelect = { [weak self] index in
            guard let self, self.active else { return }
            self.selectCandidate(at: range.lowerBound + index)
        }
        panel.onNavigate = { [weak self] action in
            guard let self, self.active else { return }
            self.navigateCandidates(action)
        }
        panel.showGrid(items: items, selected: candidateNavigation.selected - range.lowerBound,
                       expanded: candidateNavigation.expanded,
                       canPrevious: candidateNavigation.start > 0,
                       canNext: range.upperBound < nativeCandidates.count || hasMoreCandidates,
                       status: jevOrder != nil ? (jevOrder!.ranking.personalized ? "Jev · 已按用词习惯调整" : "Jev · 完整匹配优先") : jevStatus,
                       page: candidateNavigation.start / candidateNavigation.capacity + 1,
                       anchor: anchor())
    }
    private func cancelJev(clearOrder: Bool = true) {
        jevGeneration = UUID()
        jevTask?.cancel(); jevTask = nil
        if clearOrder {
            jevOrder = nil; jevPool = []; jevStatus = ""
            candidateNavigation = CandidateNavigation()
            nativeCandidates = []; hasMoreCandidates = true
        }
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
                let personalized = ranking.applyingLearning(CandidateLearningStore.shared.learning, context: context)
                self.jevOrder = JevCandidateOrder(ranking: personalized, pageSize: pageSize)
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
    // 猜你想说: on the shortcut, the helper reads the focused window and the local model
    // guesses what to type. Any other key, click, voice press or focus change cancels it.
    private func startGuess() {
        cancelGuess()
        correctionUndo = nil
        if hasMarkedText || !engine.rawInput().isEmpty { commitComposition(nil) }
        guard active, Self.activeController === self, let destination = client(),
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != "org.localinput.Voice" else { return }
        let id = UUID()
        let prefix = precedingText(destination)
        guessID = id
        guessOrigin = GuessOrigin(client: ObjectIdentifier(destination as AnyObject), pid: app.processIdentifier,
                                  selection: destination.selectedRange(), prefix: prefix)
        do {
            try LocalPaths.prepare()
            try LocalPaths.write(ContextRequest(id: id, pid: app.processIdentifier, precedingText: prefix ?? "",
                                                caret: caretLine(destination, prefix: prefix), created: Date()), to: LocalPaths.file(id, "context"))
        } catch { showGuessNotice("猜你想说暂不可用", detail: error.localizedDescription); return }
        guessObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("org.localinput.context.reply"), object: id.uuidString, queue: .main) { [weak self] _ in
                self?.receiveGuess(id)
            }
        launchCompanion(activate: false) { [weak self] error in
            guard let self, self.guessID == id else { return }
            if let error { self.showGuessNotice("猜你想说暂不可用", detail: error.localizedDescription); return }
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("org.localinput.context.start"), object: id.uuidString, userInfo: nil, deliverImmediately: true)
        }
        panel.onSelect = nil
        panel.show(title: "✦ 正在猜你想说…", detail: "读取当前窗口，本机推测 · Esc 取消", anchor: anchor())
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.guessID == id, self.guesses.isEmpty else { return }
            self.showGuessNotice("猜你想说超时", detail: "本机模型可能仍在加载，稍后再试")
        }
    }
    private func receiveGuess(_ id: UUID) {
        guard guessID == id, let reply = LocalPaths.read(ContextReply.self, from: LocalPaths.file(id, "guess")) else { return }
        guard guessStillValid() else { cancelGuess(); return }
        switch reply.phase {
        case "ready" where !reply.suggestions.isEmpty:
            guesses = Array(reply.suggestions.prefix(ContextGuess.maximumSuggestions))
            guessSource = reply.source ?? ""
            // Previewing the highlighted suggestion as marked text is what makes apps with their
            // own text engines leave ↑↓ and Esc to the input method, as while typing pinyin.
            if let destination = client() {
                let adapter = IMKVoiceTextClient(client: destination)
                let preview = VoiceComposition(client: adapter)
                if preview.canPreview {
                    guard preview.update(guesses[0], client: adapter) else { cancelGuess(); return }
                    guessPreview = preview
                }
            }
            showGuesses()
        case "error": showGuessNotice("猜你想说暂不可用", detail: reply.detail + " · 详见轻言设置")
        default: showGuessNotice("没有猜到", detail: reply.detail.isEmpty ? "当前窗口没有足够的上下文" : reply.detail)
        }
    }
    // From the first character of the caret's line to the caret: where the input box's
    // text starts, even when something is already typed. The helper reads the column above it.
    private func caretLine(_ destination: IMKTextInput, prefix: String?) -> NSRect {
        let caret = anchor()
        let selection = destination.selectedRange()
        guard let line = prefix?.components(separatedBy: .newlines).last, !line.isEmpty,
              selection.location != NSNotFound, selection.location >= line.utf16.count else { return caret }
        let start = destination.firstRect(forCharacterRange: NSRange(location: selection.location - line.utf16.count, length: 0), actualRange: nil)
        guard start.height > 0, start.minX < caret.minX, caret.minX - start.minX < 4000 else { return caret }
        return NSRect(x: start.minX, y: caret.minY, width: caret.maxX - start.minX, height: caret.height)
    }
    // Pressing the shortcut always gets an answer, including why nothing was guessed.
    private func showGuessNotice(_ title: String, detail: String) {
        cancelGuess()
        guessNotice = true
        panel.onSelect = nil
        panel.show(title: title, detail: detail + " · Esc 关闭", anchor: anchor())
    }
    // The guess belongs to the exact field, caret and text it was made for.
    private func guessStillValid() -> Bool {
        guard let origin = guessOrigin, active, Self.activeController === self, voiceID == nil, !hasMarkedText,
              engine.rawInput().isEmpty, NSWorkspace.shared.frontmostApplication?.processIdentifier == origin.pid,
              let current = client(), ObjectIdentifier(current as AnyObject) == origin.client else { return false }
        let unchanged = guessPreview.map { $0.matches(IMKVoiceTextClient(client: current)) } ?? (current.selectedRange() == origin.selection)
        return unchanged && precedingText(current) == origin.prefix
    }
    private func showGuesses() {
        panel.onSelect = { [weak self] index in self?.acceptGuess(index) }
        panel.show(title: "✦ 猜你想说", candidates: guesses, selected: guessSelected,
                   detail: "↑↓ 选择  Enter 输入  Esc 取消 · " + (guessSource.isEmpty ? "本机根据当前窗口推测" : "来源：\(guessSource)"),
                   anchor: anchor())
    }
    private func moveGuess(_ step: Int) {
        guessSelected = (guessSelected + step + guesses.count) % guesses.count
        if let preview = guessPreview, let destination = client(),
           !preview.update(guesses[guessSelected], client: IMKVoiceTextClient(client: destination)) { cancelGuess(); return }
        showGuesses()
    }
    private func acceptGuess(_ index: Int) {
        guard guesses.indices.contains(index), guessStillValid(), let destination = client() else { cancelGuess(); return }
        let text = guesses[index], preview = guessPreview
        // Detach before the client call, which can reenter the controller.
        guessPreview = nil
        cancelGuess()
        if let preview { preview.commit(text, client: IMKVoiceTextClient(client: destination)) }
        else { destination.insertText(text, replacementRange: replacement) }
    }
    private func cancelGuess() {
        let preview = guessPreview
        guessPreview = nil
        if let id = guessID {
            if guesses.isEmpty, guessOrigin != nil {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("org.localinput.context.cancel"), object: id.uuidString, userInfo: nil, deliverImmediately: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { LocalPaths.remove(id, suffixes: ["context", "guess"]) }
        }
        if let observer = guessObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            guessObserver = nil
        }
        let shown = guessID != nil || guessNotice
        guessID = nil; guessOrigin = nil; guesses = []; guessSelected = 0; guessNotice = false; guessSource = ""
        if shown { panel.orderOut(nil) }
        // Takes back the previewed suggestion, restoring what was there.
        if let preview, let destination = client() { preview.cancel(client: IMKVoiceTextClient(client: destination)) }
    }
    private var replacement: NSRange { NSRange(location: NSNotFound, length: NSNotFound) }
    override func commitComposition(_ sender: Any!) {
        // A host finalizing its composition must not keep an unchosen suggestion.
        if guessPreview != nil { cancelGuess() }
        let selected = nativeCandidates.isEmpty ? nil : candidateEngineIndex(candidateNavigation.selected)
        let spelling = engine.rawInput()
        cancelJev()
        if let selected { engine.selectGlobal(UInt(selected)) }
        if !engine.rawInput().isEmpty {
            engine.commit()
            refresh(learningSpelling: spelling)
        } else if selected != nil { refresh(learningSpelling: spelling) }
    }
    override func hidePalettes() { cancelJev(); cancelGuess(); panel.orderOut(nil) }
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
        if Settings.load().contextGuessEnabled {
            menu.addItem(withTitle: "猜我想说（\(Settings.load().guessShortcut.displayName)）", action: #selector(guessNow(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "语音快捷键：\(Settings.load().voiceShortcut.displayName)", action: nil, keyEquivalent: "")
        menu.addItem(hint)
        return menu
    }
    private func switchTypingMode() {
        cancelJev()
        cancelGuess()
        if !english {
            let raw = engine.takeRawInput()
            // Clear engine/IME state before insertText, which can reenter the controller.
            english = true
            hasMarkedText = false
            panel.orderOut(nil)
            if !raw.isEmpty { client()?.insertText(raw, replacementRange: replacement); recordWords(raw, .typed) }
        } else {
            english = false
            panel.orderOut(nil)
        }
    }
    @objc private func toggleMode(_ sender: Any?) { switchTypingMode() }
    private func recordWords(_ text: String, _ source: WordStats.Source) {
        let settings = Settings.load()
        guard settings.wordStatsEnabled else { return }
        WordStatsRecorder.shared.record(text, source: source, vocabulary: settings.voiceVocabulary)
    }
    @objc private func openSettings(_ sender: Any?) { launchCompanion(activate: true) }
    @objc private func guessNow(_ sender: Any?) { startGuess() }
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
        cancelGuess()
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
        guard composition.commit(text, client: adapter) else { return }
        recordWords(text, .voice)
        if let original, original != text, start != NSNotFound {
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
