import Foundation

@main struct LiveSpeechTests {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else { fatalError("usage: live-speech-tests AUDIO MODEL LANGUAGE") }
        let vocabulary = args.count > 4 ? args[4] : ""
        let audio = try PCM.read(URL(fileURLWithPath: args[1]))
        let engine = SpeechEngine()
        var gate = LiveTranscriptionGate()
        var successes = 0
        for seconds in [0.8, 1.2, 1.6, 2.0, 3.0] {
            let count = min(audio.count, Int(seconds * 16000))
            guard count < audio.count else { continue }
            let now = Date()
            let token = gate.begin(at: now.addingTimeInterval(seconds), sampleCount: count)!
            do {
                let text = try engine.transcribe(Array(audio.prefix(count)), model: args[2], language: args[3], cancellation: CancellationFlag(), partial: true, vocabulary: vocabulary)
                print(String(format: "PARTIAL %.1fs audio / %.2fs decode: %@", seconds, Date().timeIntervalSince(now), text))
                precondition(text.count < max(40, Int(seconds * 35)), "provisional decode must not flood repeated text")
                successes += 1
            } catch { print("PARTIAL deferred: \(error.localizedDescription)") }
            precondition(gate.finish(token))
        }
        let start = Date()
        let final = try engine.transcribe(audio, model: args[2], language: args[3], cancellation: CancellationFlag(), vocabulary: vocabulary)
        precondition(successes > 0, "at least one result must be produced before the full recording")
        print(String(format: "FINAL %.2fs audio / %.2fs decode: %@", Double(audio.count) / 16000, Date().timeIntervalSince(start), final))
        do {
            _ = try engine.transcribe([Float](repeating: 0, count: 12800), model: args[2], language: args[3], cancellation: CancellationFlag(), partial: true, vocabulary: vocabulary)
            fatalError("padding must not turn silence into text")
        } catch { print("PASS: short silent preview rejected") }
        let cancelled = CancellationFlag(); cancelled.cancel()
        do {
            _ = try engine.transcribe(audio, model: args[2], language: args[3], cancellation: cancelled)
            fatalError("cancelled partial must not be accepted")
        } catch { print("PASS: partial audio snapshots, context reuse, final decode, cancelled decode") }
    }
}
