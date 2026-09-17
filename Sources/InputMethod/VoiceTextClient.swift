import AppKit
import InputMethodKit

struct IMKVoiceTextClient: VoiceTextClient {
    let client: IMKTextInput
    var voiceSelection: NSRange { client.selectedRange() }
    var voiceMarkedRange: NSRange { client.markedRange() }
    func voiceSubstring(_ range: NSRange) -> NSAttributedString? { client.attributedSubstring(from: range) }
    func voiceMark(_ text: String) {
        client.setMarkedText(text, selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }
    func voiceInsert(_ text: NSAttributedString) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }
}
