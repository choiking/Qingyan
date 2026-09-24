import AppKit

// Answers 猜你想说 requests from the input method: read the focused window, ask the
// local model, reply through private IPC. One request at a time; a newer one or a
// cancel from the input method (typing, focus change) stops the model.
final class ContextGuessService: ObservableObject {
    @Published var status = "尚未读取上下文"
    @Published var lastContext = ""
    @Published var lastSuggestions: [String] = []
    @Published private(set) var accessibilityGranted = ContextReader.accessibilityGranted
    @Published private(set) var screenGranted = ContextReader.screenGranted
    @Published private(set) var testing = false
    private let corrector: LocalCorrector
    private var task: Task<Void, Never>?
    private var current: UUID?
    private var handled = Set<UUID>()
    private var lastReadAt: Date?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(corrector: LocalCorrector) {
        self.corrector = corrector
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: NSNotification.Name("org.localinput.context.start"), object: nil, queue: .main) { [weak self] note in
            guard let object = note.object as? String, let id = UUID(uuidString: object) else { return }
            self?.receive(id)
        })
        observers.append(center.addObserver(forName: NSNotification.Name("org.localinput.context.cancel"), object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? String == self.current?.uuidString else { return }
            self.task?.cancel(); self.task = nil; self.current = nil
        })
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            if let self, let at = self.lastReadAt, Date().timeIntervalSince(at) > 600 { self.clear() }
        }
        if Settings.load().contextGuessEnabled { ContextReader.prepareRecognizer() }
        // Covers a request written before this helper was running.
        let files = (try? FileManager.default.contentsOfDirectory(at: LocalPaths.ipc, includingPropertiesForKeys: nil)) ?? []
        if let newest = files.filter({ $0.lastPathComponent.hasSuffix(".context.json") })
            .compactMap({ LocalPaths.read(ContextRequest.self, from: $0) }).max(by: { $0.created < $1.created }) {
            receive(newest.id)
        }
    }
    func refreshPermissions() {
        accessibilityGranted = ContextReader.accessibilityGranted
        screenGranted = ContextReader.screenGranted
    }
    private func receive(_ id: UUID) {
        guard !handled.contains(id), let request = LocalPaths.read(ContextRequest.self, from: LocalPaths.file(id, "context")),
              request.id == id, Date().timeIntervalSince(request.created) < 10 else { return }
        handled.insert(id)
        task?.cancel()
        current = id
        let settings = Settings.load()
        guard settings.contextGuessEnabled else { return reply(id, ContextReply(phase: "error", detail: "猜你想说已在设置中关闭")) }
        refreshPermissions()
        let source = ContextSource(rawValue: settings.contextSource) ?? .auto
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                // Only the app the user is typing in, and only while it is still in front.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == request.pid else {
                    self.reply(id, ContextReply(phase: "empty", detail: "焦点已切换到其他应用")); return
                }
                let context = try await ContextReader.read(request, source: source)
                try Task.checkCancellation()
                guard !context.text.isEmpty || !request.precedingText.isEmpty else {
                    self.status = "没有读到可用的上下文"
                    self.reply(id, ContextReply(phase: "empty", detail: "没有读到当前窗口的文字，可在轻言设置中检查权限")); return
                }
                self.lastContext = context.text; self.lastReadAt = Date()
                let raw = try await self.corrector.guess(context, precedingText: request.precedingText)
                try Task.checkCancellation()
                self.lastSuggestions = ContextGuess.accept(raw, precedingText: request.precedingText, screen: context.text)
                let source = context.text.isEmpty ? "光标前文字" : context.source
                self.status = "\(context.app) · \(source) \(context.text.count) 字 · " +
                    String(format: "用时 %.1f 秒", Date().timeIntervalSince(started))
                self.reply(id, self.lastSuggestions.isEmpty ? ContextReply(phase: "empty", detail: "本机模型没有给出合适的句子") :
                    ContextReply(phase: "ready", suggestions: self.lastSuggestions, source: source))
            } catch {
                // Typing or a focus change cancelled it; URLSession reports that as a URLError.
                guard !Task.isCancelled else { return }
                self.status = error.localizedDescription
                self.reply(id, ContextReply(phase: "error", detail: error.localizedDescription))
            }
        }
    }
    private func reply(_ id: UUID, _ value: ContextReply) {
        guard current == id else { return }
        current = nil
        try? LocalPaths.write(value, to: LocalPaths.file(id, "guess"))
        // Announce only the private session ID. Suggestions remain in private IPC storage.
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("org.localinput.context.reply"), object: id.uuidString, userInfo: nil, deliverImmediately: true)
    }
    func testExample() {
        testing = true; status = "正在用示例测试本地模型…"
        let context = ScreenContext(app: "微信", window: "李雷",
            text: ContextGuess.excerpt(before: ["李雷", "周六下午有空吗？一起去打羽毛球吧", "我订了三点的场地"], after: []), source: "示例")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.testing = false }
            let started = Date()
            do {
                let raw = try await self.corrector.guess(context, precedingText: "")
                self.lastContext = context.text; self.lastReadAt = Date()
                self.lastSuggestions = ContextGuess.accept(raw, precedingText: "", screen: context.text)
                self.status = String(format: "示例完成 · 用时 %.1f 秒", Date().timeIntervalSince(started))
            } catch { self.status = error.localizedDescription }
        }
    }
    func clear() {
        lastContext = ""; lastSuggestions = []; lastReadAt = nil
        status = "最近一次读取的内容已清除"
    }
    func shutdown() {
        task?.cancel(); task = nil
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
    }
}
