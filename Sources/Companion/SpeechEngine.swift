import AVFoundation

enum SpeechError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

final class CancellationFlag {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

enum PCM {
    static func resample(_ source: AVAudioPCMBuffer) throws -> [Float] {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(Double(source.frameLength) * 16000 / source.format.sampleRate) + 512) else {
            throw SpeechError.message("无法转换麦克风音频格式")
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .endOfStream; return nil }
            consumed = true; inputStatus.pointee = .haveData; return source
        }
        if let error { throw error }
        guard status != .error, let data = output.floatChannelData?[0] else { throw SpeechError.message("音频转换失败") }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 120),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SpeechError.message("请选择不超过 120 秒的音频")
        }
        try file.read(into: buffer)
        return try resample(buffer)
    }
}

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48000
    private var tapped = false
    private var accepting = false
    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.message("没有可用的麦克风") }
        sampleRate = format.sampleRate
        lock.lock(); samples = []; accepting = true; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let n = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: count)
            for c in 0..<n { for i in 0..<count { mono[i] += channels[c][i] / Float(n) } }
            self.lock.lock()
            if self.accepting {
                let remaining = max(0, Int(self.sampleRate * 60) - self.samples.count)
                self.samples.append(contentsOf: mono.prefix(remaining))
            }
            self.lock.unlock()
        }
        tapped = true
        engine.prepare()
        do { try engine.start() } catch { discard(); throw error }
    }
    private func stopCapture() -> [Float] {
        lock.lock(); accepting = false; lock.unlock()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        let result = samples; samples = []; return result
    }
    func finish() throws -> [Float] {
        try convert(stopCapture())
    }
    func snapshot() throws -> [Float] {
        lock.lock(); let audio = samples; lock.unlock()
        return try convert(audio)
    }
    private func convert(_ audio: [Float]) throws -> [Float] {
        guard !audio.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)),
              let target = buffer.floatChannelData?[0] else { throw SpeechError.message("未录到声音") }
        buffer.frameLength = AVAudioFrameCount(audio.count)
        audio.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: $0.count) }
        return try PCM.resample(buffer)
    }
    func discard() { _ = stopCapture() }
}

// Confined to one serial worker queue. Never called on the input method's thread.
// SenseVoice is non-autoregressive: each decode runs the whole snapshot in one
// pass, so live previews and the final result share the same path.
final class SpeechEngine {
    private var recognizer: OpaquePointer?
    private var loadedKey = ""
    deinit { if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer) } }
    // The language is fixed per recognizer; switching it reloads the model.
    func prepare(model: String, language: String) throws {
        let key = model + "\n" + language
        guard recognizer == nil || loadedKey != key else { return }
        if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }; recognizer = nil
        let tokens = URL(fileURLWithPath: model).deletingLastPathComponent().appendingPathComponent("tokens.txt").path
        guard FileManager.default.fileExists(atPath: model), FileManager.default.fileExists(atPath: tokens) else {
            throw SpeechError.message("找不到离线模型，请在设置中选择 SenseVoice 模型（同目录需有 tokens.txt）")
        }
        // The C API copies every string while building its config.
        let strings = [model, tokens, language, "cpu", "greedy_search"].map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = UnsafePointer(strings[0])
        config.model_config.tokens = UnsafePointer(strings[1])
        config.model_config.sense_voice.language = UnsafePointer(strings[2])
        // Inverse text normalization adds punctuation and writes numbers as digits.
        config.model_config.sense_voice.use_itn = 1
        config.model_config.provider = UnsafePointer(strings[3])
        config.model_config.num_threads = Int32(min(6, max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
        config.decoding_method = UnsafePointer(strings[4])
        recognizer = SherpaOnnxCreateOfflineRecognizer(&config)
        guard recognizer != nil else { throw SpeechError.message("无法加载模型，请在设置中选择有效的 SenseVoice 模型") }
        loadedKey = key
    }
    func transcribe(_ samples: [Float], model: String, language: String, cancellation: CancellationFlag) throws -> String {
        guard samples.count >= 4000 else { throw SpeechError.message("录音太短，请说完一句话后再停止") }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        guard rms > 0.002 else { throw SpeechError.message("没有检测到清晰语音，请检查麦克风") }
        if cancellation.cancelled { throw SpeechError.message("已取消") }
        try prepare(model: model, language: language)
        guard let recognizer, let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw SpeechError.message("模型未就绪") }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32($0.count)) }
        // A decode cannot be interrupted, but it is short; a cancelled result is discarded.
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        if cancellation.cancelled { throw SpeechError.message("已取消") }
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw SpeechError.message("本地识别失败") }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        var text = result.pointee.text.map { String(cString: $0) } ?? ""
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        guard !text.isEmpty else { throw SpeechError.message("未识别到语音，请再试一次") }
        return text
    }
}
