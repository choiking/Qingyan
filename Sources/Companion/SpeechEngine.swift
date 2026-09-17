import AVFoundation
import whisper

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
final class SpeechEngine {
    private var context: OpaquePointer?
    private var partialState: OpaquePointer?
    private var loadedPath = ""
    deinit {
        if let partialState { whisper_free_state(partialState) }
        if let context { whisper_free(context) }
    }
    func prepare(model: String) throws {
        if context == nil || loadedPath != model {
            if let partialState { whisper_free_state(partialState) }; partialState = nil
            if let context { whisper_free(context) }; context = nil
            var config = whisper_context_default_params()
            config.use_gpu = true
            context = model.withCString { whisper_init_from_file_with_params($0, config) }
            guard context != nil else { throw SpeechError.message("无法加载模型，请在设置中选择有效的多语言模型") }
            loadedPath = model
        }
        // Share model weights but isolate the preview decoder's shortened context
        // from the final decoder (including automatic language detection).
        if partialState == nil, let context {
            partialState = whisper_init_state(context)
            guard partialState != nil else { throw SpeechError.message("无法准备实时识别状态") }
        }
    }
    func transcribe(_ samples: [Float], model: String, language: String, cancellation: CancellationFlag, partial: Bool = false, vocabulary: String = "") throws -> String {
        guard samples.count >= 4000 else { throw SpeechError.message("录音太短，请说完一句话后再停止") }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        guard rms > 0.002 else { throw SpeechError.message("没有检测到清晰语音，请检查麦克风") }
        if cancellation.cancelled { throw SpeechError.message("已取消") }
        try prepare(model: model)
        guard let context else { throw SpeechError.message("模型未就绪") }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(6, max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.translate = false
        params.no_context = true
        params.no_timestamps = true
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.suppress_blank = true
        params.suppress_nst = true
        if partial {
            // Match the provisional encoder context to available audio, with a one-second
            // margin, instead of encoding the default 30-second context every update.
            let frames = (samples.count + 319) / 320 + 50
            params.audio_ctx = min(whisper_model_n_audio_ctx(context), Int32(max(512, ((frames + 63) / 64) * 64)))
            params.single_segment = samples.count <= 480000
            params.max_tokens = samples.count < 128000 ? Int32(max(24, (samples.count / 16000 + 1) * 12)) : 0
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        params.abort_callback = { pointer in
            guard let pointer else { return false }
            return Unmanaged<CancellationFlag>.fromOpaque(pointer).takeUnretainedValue().cancelled
        }
        // whisper.cpp 1.7.5 skips input shorter than one second. Pad only the
        // provisional decode; captured audio and final transcription stay untouched.
        let decodeSamples = partial && samples.count < 17600 ?
            samples + [Float](repeating: 0, count: 17600 - samples.count) : samples
        let prompt = vocabulary
        let result = prompt.withCString { hint in
        language.withCString { lang in
            params.initial_prompt = prompt.isEmpty ? nil : hint
            params.language = lang
            return decodeSamples.withUnsafeBufferPointer {
                if partial {
                    return whisper_full_with_state(context, partialState, params, $0.baseAddress, Int32($0.count))
                }
                return whisper_full(context, params, $0.baseAddress, Int32($0.count))
            }
        }
        }
        if cancellation.cancelled { throw SpeechError.message("已取消") }
        guard result == 0 else { throw SpeechError.message("本地识别失败（\(result)）") }
        var text = ""
        let segmentCount = partial ? whisper_full_n_segments_from_state(partialState) : whisper_full_n_segments(context)
        for i in 0..<segmentCount {
            // A silent segment must not become hallucinated input.
            let noSpeech = partial ? whisper_full_get_segment_no_speech_prob_from_state(partialState, i) :
                whisper_full_get_segment_no_speech_prob(context, i)
            if noSpeech > 0.6 { continue }
            let segment = partial ? whisper_full_get_segment_text_from_state(partialState, i) : whisper_full_get_segment_text(context, i)
            if let segment { text += String(cString: segment) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        guard !text.isEmpty else { throw SpeechError.message("未识别到语音，请再试一次") }
        return text
    }
}
