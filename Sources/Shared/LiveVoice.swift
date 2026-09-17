import Foundation

// One in-flight decode, no backlog of stale audio snapshots.
struct LiveTranscriptionGate {
    static let firstAudioDuration: TimeInterval = 0.8
    static let updateInterval: TimeInterval = 0.35
    static let minimumNewSamples = 5600 // 350 ms at 16 kHz
    private(set) var job: UUID?
    private var lastStart = Date.distantPast
    private var lastSampleCount = 0
    func canStart(at now: Date) -> Bool { job == nil && now.timeIntervalSince(lastStart) >= Self.updateInterval }
    mutating func begin(at now: Date, sampleCount: Int) -> UUID? {
        guard canStart(at: now), sampleCount >= Int(Self.firstAudioDuration * 16000), sampleCount - lastSampleCount >= Self.minimumNewSamples else { return nil }
        let id = UUID(); job = id; lastStart = now; lastSampleCount = sampleCount
        return id
    }
    mutating func finish(_ id: UUID) -> Bool {
        guard job == id else { return false }
        job = nil; return true
    }
    mutating func invalidate() { job = nil }
}

protocol VoiceTextClient {
    var voiceSelection: NSRange { get }
    var voiceMarkedRange: NSRange { get }
    func voiceSubstring(_ range: NSRange) -> NSAttributedString?
    func voiceMark(_ text: String)
    func voiceInsert(_ text: NSAttributedString)
}

// Revisions replace one owned marked range, rather than appending snapshots.
final class VoiceComposition {
    private var expectedSelection: NSRange
    private var expectedMarked: NSRange?
    private var originalText: NSAttributedString?
    private var ended = false
    private(set) var draft = ""
    let canPreview: Bool

    init(client: VoiceTextClient) {
        let selection = client.voiceSelection
        expectedSelection = selection
        if selection.length == 0 { originalText = NSAttributedString(string: "") }
        else if selection.location != NSNotFound, selection.length != NSNotFound,
                let original = client.voiceSubstring(selection), original.length == selection.length {
            originalText = original
        }
        canPreview = selection.location != NSNotFound && originalText != nil
    }
    func matches(_ client: VoiceTextClient) -> Bool {
        !ended && client.voiceSelection == expectedSelection &&
            (expectedMarked == nil || client.voiceMarkedRange == expectedMarked)
    }
    @discardableResult func update(_ text: String, client: VoiceTextClient) -> Bool {
        guard matches(client) else { return false }
        guard canPreview, !text.isEmpty, draft != text else { return true }
        // The native client replaces its existing marked text at NSNotFound.
        client.voiceMark(text)
        let marked = client.voiceMarkedRange
        guard marked.location != NSNotFound, marked.length == text.utf16.count else {
            // The host did not maintain a composition. Never append another snapshot/final.
            ended = true; return false
        }
        draft = text; expectedMarked = marked; expectedSelection = client.voiceSelection
        return true
    }
    @discardableResult func commit(_ text: String, client: VoiceTextClient) -> Bool {
        guard !text.isEmpty, matches(client) else { return false }
        ended = true // insertText may synchronously reenter the controller.
        client.voiceInsert(NSAttributedString(string: text))
        return true
    }
    func cancel(client: VoiceTextClient) {
        let restore = matches(client) && expectedMarked != nil
        ended = true
        if restore, let originalText { client.voiceInsert(originalText) }
    }
}

// Restore only our just-committed text at the unchanged caret; never search a document.
struct VoiceCorrectionUndo {
    let original: String
    let corrected: String
    let range: NSRange
    let created: Date
    func replacementRange(in client: VoiceTextClient, now: Date = Date()) -> NSRange? {
        guard now.timeIntervalSince(created) < 600, range.location != NSNotFound,
              (client.voiceMarkedRange.location == NSNotFound || client.voiceMarkedRange.length == 0),
              client.voiceSelection == NSRange(location: range.location + range.length, length: 0),
              client.voiceSubstring(range)?.string == corrected else { return nil }
        return range
    }
}
