import AppKit
import AVFoundation
import Combine

final class VoiceService: NSObject, ObservableObject {
    @Published var phase = "idle"
    @Published var detail = "中文、英文，都留在这台 Mac。"
    @Published var transcript = ""
    @Published var originalTranscript = ""
    @Published var correctionStatus = "尚未检查本地纠错模型"
    @Published var preparingCorrection = false
    private let corrector = LocalCorrector()
    // 猜你想说 shares the local model server with correction.
    lazy var guesser = ContextGuessService(corrector: corrector)
    private var correctionTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var sessionVocabulary = ""
    private var sessionCorrectionEnabled = false
    @Published var settings = Settings.load()
    @Published private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var requestingMicrophone = false
    var microphoneGranted: Bool { microphoneStatus == .authorized }
    var microphoneButtonTitle: String {
        if requestingMicrophone { return "等待系统授权…" }
        switch microphoneStatus {
        case .authorized: return "麦克风已授权"
        case .denied: return "打开麦克风权限设置"
        case .restricted: return "麦克风受到系统限制"
        default: return "授予麦克风权限"
        }
    }
    private let capture = MicrophoneCapture()
    private let recognizer = SpeechEngine()
    private let worker = DispatchQueue(label: "org.localinput.recognizer", qos: .userInitiated)
    private var cancellation = CancellationFlag()
    private var partialCancellation = CancellationFlag()
    private var liveGate = LiveTranscriptionGate()
    private var request: VoiceRequest?
    private var timer: Timer?
    private var recordingStarted = Date()
    private var lastResultAt: Date?
    private var handled = Set<UUID>()
    var modelURL: URL {
        // A path saved for the former Whisper engine (.bin) falls back to the bundled model.
        if !settings.modelPath.isEmpty, settings.modelPath.lowercased().hasSuffix(".onnx") {
            return URL(fileURLWithPath: settings.modelPath)
        }
        return Bundle.main.resourceURL!.appendingPathComponent("Models/sense-voice/model.int8.onnx")
    }
    var busy: Bool { ["starting", "recording", "transcribing", "correcting"].contains(phase) }
    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(startNotification(_:)),
            name: NSNotification.Name("org.localinput.voice.start"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(commandNotification(_:)),
            name: NSNotification.Name("org.localinput.voice.command"), object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        // Prepare the local model on the same serial worker, without opening the microphone.
        let model = modelURL.path, language = settings.language
        worker.async { [weak self] in try? self?.recognizer.prepare(model: model, language: language) }
        // Covers launch before the notification listener is connected.
        if settings.correctionEnabled || settings.contextGuessEnabled { prepareCorrection() }
        _ = guesser
        discoverRequest()
    }
    @objc private func startNotification(_ note: Notification) {
        guard let object = note.object as? String, let id = UUID(uuidString: object) else { return }
        receive(id)
    }
    @objc private func commandNotification(_ note: Notification) {
        guard note.object as? String == request?.id.uuidString else { return }
        tick()
    }
    private func discoverRequest() {
        let files = (try? FileManager.default.contentsOfDirectory(at: LocalPaths.ipc, includingPropertiesForKeys: nil)) ?? []
        let pending = files.filter { $0.lastPathComponent.hasSuffix(".request.json") }
            .compactMap { LocalPaths.read(VoiceRequest.self, from: $0) }
            .filter { Date().timeIntervalSince($0.created) < 20 && !handled.contains($0.id) }
            .sorted { $0.created > $1.created }
        if let newest = pending.first { receive(newest.id) }
    }
    private func receive(_ id: UUID) {
        guard !handled.contains(id), let value = LocalPaths.read(VoiceRequest.self, from: LocalPaths.file(id, "request")),
              value.id == id, Date().timeIntervalSince(value.created) < 20 else { return }
        if LocalPaths.read(VoiceCommand.self, from: LocalPaths.file(id, "command"))?.action == "cancel" {
            handled.insert(id); LocalPaths.remove(id); return
        }
        handled.insert(id)
        cancel()
        request = value
        settings = Settings.load()
        sessionVocabulary = VoiceVocabulary.normalize(settings.voiceVocabulary).joined(separator: "\n")
        sessionCorrectionEnabled = settings.correctionEnabled
        cancellation = CancellationFlag()
        liveGate = LiveTranscriptionGate()
        transcript = ""; originalTranscript = ""
        publish("starting", "正在准备麦克风…")
        // Permissions are requested from the visible setup app, before dictation.
        refreshMicrophonePermission()
        guard microphoneGranted else {
            publish("error", microphoneStatus == .denied ?
                "麦克风权限被拒绝，请在系统设置中允许“轻言输入法”使用麦克风" :
                "请打开轻言设置，点击“授予麦克风权限”，然后在系统弹窗中允许")
            return
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            publish("error", "找不到离线模型，请在设置中选择模型")
            return
        }
        switch value.captureAdmission(
            command: LocalPaths.read(VoiceCommand.self, from: LocalPaths.file(id, "command"))?.action,
            lease: LocalPaths.read(VoiceHoldLease.self, from: LocalPaths.file(id, "hold")), now: Date()) {
        case .allowed: break
        case .released:
            publish("error", "按键已松开，未开始录音；请按住快捷键，看到正在聆听后说话。")
            return
        case .cancelled: cancel(); return
        case .disconnected:
            publish("error", "与输入法的连接已中断，未开始录音；请重新触发语音。")
            return
        }
        do {
            try capture.start()
            recordingStarted = Date()
            publish("recording", "正在聆听 · 最长 60 秒")
        } catch { publish("error", error.localizedDescription) }
    }
    func refreshMicrophonePermission() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    func requestMicrophone(startAfterGrant: Bool = false) {
        guard !requestingMicrophone else { return }
        refreshMicrophonePermission()
        if microphoneGranted {
            if startAfterGrant { testRecording() }
            return
        }
        if microphoneStatus == .restricted {
            detail = "麦克风受到系统或设备管理限制，无法在应用内授权。"
            return
        }
        if microphoneStatus == .denied {
            detail = "请在系统设置 → 隐私与安全性 → 麦克风中，允许“轻言输入法”（或“轻言语音”）。"
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        requestingMicrophone = true
        detail = "请在 macOS 授权弹窗中选择“允许”。"
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.requestingMicrophone = false
                self.refreshMicrophonePermission()
                self.detail = granted ? "麦克风已授权，点击“测试语音”或使用语音快捷键开始。" :
                    "麦克风未获授权，请在系统设置 → 隐私与安全性 → 麦克风中允许轻言。"
                if granted && startAfterGrant { self.testRecording() }
            }
        }
    }
    func testRecording() {
        if phase == "recording" { stop(); return }
        guard !busy else { return }
        refreshMicrophonePermission()
        guard microphoneGranted else { requestMicrophone(startAfterGrant: true); return }
        let value = VoiceRequest(id: UUID(), language: settings.language, created: Date())
        do {
            try settings.save()
            try LocalPaths.write(value, to: LocalPaths.file(value.id, "request"))
            receive(value.id)
        } catch { detail = error.localizedDescription }
    }
    private func tick() {
        if let id = request?.id {
            if let command = LocalPaths.read(VoiceCommand.self, from: LocalPaths.file(id, "command")) {
                try? FileManager.default.removeItem(at: LocalPaths.file(id, "command"))
                if command.action == "cancel" { cancel(); LocalPaths.remove(id); return }
                if command.action == "stop" { stop() }
            }
        }
        // A crashed/unresponsive IMK owner must not leave the microphone running.
        // Connection loss cancels the audio; it never impersonates a key release.
        if phase == "recording", let value = request,
           value.captureAdmission(command: nil,
               lease: LocalPaths.read(VoiceHoldLease.self, from: LocalPaths.file(value.id, "hold")), now: Date()) == .disconnected {
            capture.discard()
            partialCancellation.cancel(); liveGate.invalidate()
            publish("error", "与输入法的连接已中断，录音已取消；请重新触发语音。")
        }
        if phase == "recording", Date().timeIntervalSince(recordingStarted) >= 60 { stop() }
        if phase == "recording" { transcribeLive() }
        if let lastResultAt, Date().timeIntervalSince(lastResultAt) > 600 { clearTranscript() }
    }
    private func transcribeLive() {
        let now = Date()
        guard let request, now.timeIntervalSince(recordingStarted) >= LiveTranscriptionGate.firstAudioDuration,
              liveGate.canStart(at: now), let samples = try? capture.snapshot(),
              let job = liveGate.begin(at: now, sampleCount: samples.count) else { return }
        let flag = CancellationFlag()
        partialCancellation = flag
        let model = modelURL.path
        worker.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.recognizer.transcribe(samples, model: model, language: request.language, cancellation: flag) }
            DispatchQueue.main.async {
                guard self.request?.id == request.id, self.liveGate.finish(job),
                      !flag.cancelled, self.phase == "recording" else { return }
                // Silence/unfinished syllables are normal during a partial decode.
                if case .success(let text) = result {
                    self.transcript = text; self.lastResultAt = Date()
                    self.publish("recording", "正在聆听 · 文字实时更新，松开后定稿")
                }
            }
        }
    }
    func stop() {
        guard phase == "recording", let request else { return }
        partialCancellation.cancel(); liveGate.invalidate()
        do {
            let samples = try capture.finish()
            let model = modelURL.path
            let flag = cancellation
            publish("transcribing", "正在完成语音识别，录音不会上传。")
            worker.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.recognizer.transcribe(samples, model: model, language: request.language, cancellation: flag) }
                DispatchQueue.main.async {
                    guard self.request?.id == request.id, !flag.cancelled else { return }
                    switch result {
                    case .success(let text): self.finishRecognition(text, id: request.id)
                    case .failure(let error): self.publish("error", error.localizedDescription)
                    }
                }
            }
        } catch { publish("error", error.localizedDescription) }
    }
    func cancel() {
        correctionTask?.cancel(); correctionTask = nil
        cancellation.cancel()
        partialCancellation.cancel(); liveGate.invalidate()
        capture.discard()
        if let id = request?.id {
            LocalPaths.remove(id)
            // Tell the input method to withdraw its live draft when cancelled in Settings.
            try? LocalPaths.write(VoiceReply(phase: "cancelled"), to: LocalPaths.file(id, "reply"))
        }
        request = nil
        if busy { phase = "idle"; detail = "已取消，可以继续打字。" }
    }
    func clearTranscript() {
        transcript = ""; originalTranscript = ""; lastResultAt = nil
        cancel(); phase = "idle"; detail = "转写内容已清除。"
    }
    func prepareCorrection() {
        guard !preparingCorrection else { return }
        preparingCorrection = true; correctionStatus = "正在准备本地模型…"
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.preparingCorrection = false }
            do { try await self.corrector.prepare(); self.correctionStatus = "本地模型已就绪 · Qwen3 4B" }
            catch { self.correctionStatus = error.localizedDescription }
        }
    }
    private func finishRecognition(_ text: String, id: UUID) {
        transcript = text; originalTranscript = text; lastResultAt = Date()
        guard sessionCorrectionEnabled else { publish("ready", "转写完成"); return }
        guard text.count <= CorrectionPolicy.maximumCharacters else { publish("ready", "本段较长，已保留原文"); return }
        publish("correcting", "正在本地轻度纠错 · 开始打字可直接保留原文")
        let vocabulary = sessionVocabulary
        correctionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let corrected = try await self.corrector.correct(text, vocabulary: vocabulary)
                guard !Task.isCancelled, self.request?.id == id, self.phase == "correcting" else { return }
                self.transcript = corrected; self.lastResultAt = Date()
                self.publish("ready", corrected == text ? "纠错完成，原文无需修改" : "已轻度纠错 · 立即按 Esc 可恢复原文")
            } catch {
                guard !Task.isCancelled, self.request?.id == id, self.phase == "correcting" else { return }
                self.publish("ready", "已保留原文：" + error.localizedDescription)
            }
        }
        // An absolute deadline also bounds server startup and model warm-up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.request?.id == id, self.phase == "correcting" else { return }
            self.correctionTask?.cancel(); self.correctionTask = nil
            self.publish("ready", "纠错等待超时，已保留原文")
        }
    }
    // ONNX Runtime destroys static state during exit(); a model load or decode
    // still running on the worker would crash, so let it finish first.
    func waitForRecognizer() { worker.sync {} }
    func shutdown() {
        preparationTask?.cancel(); cancel(); guesser.shutdown(); corrector.shutdown(); waitForRecognizer()
    }
    func saveSettings() {
        do { try settings.save() } catch { detail = "保存设置失败：\(error.localizedDescription)" }
    }
    @discardableResult func setVoiceShortcut(_ shortcut: VoiceShortcut) -> Bool {
        guard shortcut.validationError == nil, shortcut != settings.guessShortcut else { return false }
        var updated = settings
        updated.voiceShortcut = shortcut
        do { try updated.save(); settings = updated; return true }
        catch { detail = "保存快捷键失败：\(error.localizedDescription)"; return false }
    }
    @discardableResult func setGuessShortcut(_ shortcut: VoiceShortcut) -> Bool {
        guard shortcut.validationError == nil, !shortcut.isModifier, shortcut != settings.voiceShortcut else { return false }
        var updated = settings
        updated.guessShortcut = shortcut
        do { try updated.save(); settings = updated; return true }
        catch { detail = "保存快捷键失败：\(error.localizedDescription)"; return false }
    }
    private func publish(_ phase: String, _ detail: String) {
        self.phase = phase; self.detail = detail
        if let id = request?.id {
            do {
                try LocalPaths.write(VoiceReply(phase: phase, text: transcript, detail: detail, originalText: originalTranscript.isEmpty ? nil : originalTranscript), to: LocalPaths.file(id, "reply"))
                // Announce only the private session ID. Text remains in private IPC storage.
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("org.localinput.voice.reply"), object: id.uuidString, userInfo: nil, deliverImmediately: true)
            }
            catch { self.detail = "无法传递转写状态：\(error.localizedDescription)" }
        }
    }
}
