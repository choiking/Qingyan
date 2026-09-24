import AppKit

final class NativeVoiceClient: VoiceTextClient {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    var marks = 0
    var inserts = 0
    var onInsert: (() -> Void)?
    init(_ text: String, selection: NSRange) { view.string = text; view.setSelectedRange(selection) }
    var voiceSelection: NSRange { view.selectedRange() }
    var voiceMarkedRange: NSRange { view.markedRange() }
    func voiceSubstring(_ range: NSRange) -> NSAttributedString? { view.textStorage?.attributedSubstring(from: range) }
    func voiceMark(_ text: String) {
        marks += 1
        view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }
    func voiceInsert(_ text: NSAttributedString) {
        inserts += 1
        onInsert?()
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }
}

@main struct LiveVoiceTests {
    static func main() {
        _ = NSApplication.shared
        func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
        let client = NativeVoiceClient("Before  after", selection: NSRange(location: 7, length: 0))
        let composition = VoiceComposition(client: client)
        check(composition.update("你好", client: client), "first live result accepted")
        check(client.view.string == "Before 你好 after" && client.inserts == 0,
              "partial appears directly in the native input before finalization")
        check(composition.matches(client), "caret movement caused by our own composition remains valid")
        check(composition.update("你好 👋 hello", client: client), "Unicode revision accepted")
        check(client.view.string == "Before 你好 👋 hello after", "revision replaces previous draft without duplication")
        check(composition.update("你好 👋 hello", client: client) && client.marks == 2, "duplicate snapshot does not rewrite")
        client.onInsert = { check(!composition.commit("duplicate", client: client), "reentrant finalization rejected") }
        check(composition.commit("你好，Hello！", client: client), "final result replaces marked draft")
        check(client.view.string == "Before 你好，Hello！ after" && !client.view.hasMarkedText() && client.inserts == 1,
              "final result inserted once with no leftover draft or newline")
        check(!composition.update("late", client: client), "late partial after final cannot change text")

        let selected = NativeVoiceClient("Keep OLD intact", selection: NSRange(location: 5, length: 3))
        let replacing = VoiceComposition(client: selected)
        _ = replacing.update("新的内容", client: selected)
        check(selected.view.string == "Keep 新的内容 intact", "preview replaces only selection")
        replacing.cancel(client: selected)
        check(selected.view.string == "Keep OLD intact" && !selected.view.hasMarkedText(), "cancel restores selected original text")
        let empty = NativeVoiceClient("Original", selection: NSRange(location: 8, length: 0))
        let cancelled = VoiceComposition(client: empty)
        _ = cancelled.update("temporary", client: empty)
        cancelled.cancel(client: empty)
        check(empty.view.string == "Original", "Escape/error removes owned temporary text")

        let moved = NativeVoiceClient("abc", selection: NSRange(location: 3, length: 0))
        let movedComposition = VoiceComposition(client: moved)
        _ = movedComposition.update("preview", client: moved)
        moved.view.setSelectedRange(NSRange(location: 0, length: 0))
        let afterMove = moved.view.string
        check(!movedComposition.update("late text", client: moved), "user caret movement rejects future revision")
        check(!movedComposition.commit("late final", client: moved), "user caret movement rejects final")
        movedComposition.cancel(client: moved)
        check(moved.view.string == afterMove, "cleanup never deletes unrelated text at new caret")

        let correctedClient = NativeVoiceClient("Prefix 欢迎使用轻言输入法。 suffix", selection: NSRange(location: 17, length: 0))
        let correctedText = "欢迎使用轻言输入法。"
        let undo = VoiceCorrectionUndo(original: "欢迎使用青年输入法。", corrected: correctedText,
            range: NSRange(location: 7, length: correctedText.utf16.count), created: Date())
        check(undo.replacementRange(in: correctedClient) != nil, "unchanged caret and text allow correction undo")
        correctedClient.view.insertText(undo.original, replacementRange: undo.replacementRange(in: correctedClient)!)
        check(correctedClient.view.string == "Prefix 欢迎使用青年输入法。 suffix", "undo preserves surrounding text")
        check(undo.replacementRange(in: correctedClient) == nil, "same correction cannot be undone twice")
        correctedClient.view.string = "Prefix 欢迎使用轻言输入法。 suffix"
        correctedClient.view.setSelectedRange(NSRange(location: 0, length: 0))
        check(undo.replacementRange(in: correctedClient) == nil, "moving caret prevents late replacement")
        correctedClient.view.setSelectedRange(NSRange(location: 17, length: 0))
        check(undo.replacementRange(in: correctedClient, now: Date().addingTimeInterval(601)) == nil, "restore expires")

        var gate = LiveTranscriptionGate()
        let now = Date()
        check(gate.begin(at: now, sampleCount: 12799) == nil, "do not decode below 800 ms")
        let first = gate.begin(at: now, sampleCount: 12800)!
        check(gate.begin(at: now.addingTimeInterval(5), sampleCount: 80000) == nil, "no queued partial backlog")
        check(gate.finish(first), "first result completes")
        check(gate.begin(at: now.addingTimeInterval(0.2), sampleCount: 16000) == nil, "decoding cadence bounded")
        check(gate.begin(at: now.addingTimeInterval(0.4), sampleCount: 18399) == nil, "need 350 ms of new audio")
        let second = gate.begin(at: now.addingTimeInterval(0.4), sampleCount: 18400)!
        gate.invalidate()
        let third = gate.begin(at: now.addingTimeInterval(4), sampleCount: 88000)!
        check(!gate.finish(second) && gate.job == third, "cancelled late callback cannot clear newer job")
        gate.invalidate()
        check(!gate.finish(third), "partial completing after release cannot override final")
        // 猜你想说 previews the highlighted suggestion, swaps it in place, and takes it back.
        let field = NativeVoiceClient("", selection: NSRange(location: 0, length: 0))
        let guess = VoiceComposition(client: field)
        check(guess.update("好的，我周六有空", client: field) && guess.update("可以，一起打球", client: field),
              "moving the highlight re-marks the preview")
        check(field.view.string == "可以，一起打球" && field.view.hasMarkedText(), "only the highlighted suggestion shows, still marked")
        guess.cancel(client: field)
        check(field.view.string.isEmpty && !field.view.hasMarkedText(), "Esc leaves the input box as it was")
        print("PASS: native NSTextView live composition, Unicode revisions, final replacement, reentrant/late results, selection restoration, caret guards, partial decode scheduling")
    }
}
