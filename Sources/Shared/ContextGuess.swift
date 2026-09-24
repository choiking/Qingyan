import Foundation

// 猜你想说: when a text field gains focus, the helper reads the focused window
// (accessibility text, or local OCR of a window screenshot) and asks the local
// model what the user is likely to type. Screen content never leaves this Mac.
enum ContextSource: String, Codable, CaseIterable {
    case auto, accessibility, screenshot
}

struct ContextRequest: Codable {
    let id: UUID
    let pid: pid_t
    let precedingText: String
    // The caret's line, from its first character to the caret, in Cocoa screen coordinates.
    // Text in the column above it is nearest the conversation.
    let caret: CGRect?
    let created: Date
}

struct ContextReply: Codable, Equatable {
    // "ready" carries suggestions; "empty" says why there are none; "error" needs the user's action.
    let phase: String
    var suggestions: [String] = []
    var detail = ""
    // What the suggestions were based on (界面文字 / 截图识别 / 光标前文字), shown with them.
    var source: String? = nil
}

// What was read from the focused window. Only passed to the local model.
struct ScreenContext: Equatable {
    var app = ""
    var window = ""
    var field = ""
    var text = ""
    var source = ""
}

// A piece of text on screen and where it is, in global top-left points.
struct ScreenItem: Equatable {
    let text: String
    let frame: CGRect
}

enum ContextGuess {
    enum PanelKey: Equatable { case accept, choose(Int), move(Int), dismiss }
    // Keys the suggestion panel takes while it is showing (without modifiers). Apps with their
    // own text engines (WeChat, Qt, Chromium) still act on a key the input method took unless
    // it changed marked or inserted text, so the highlighted suggestion is previewed in the
    // input box as marked text and every key taken here changes it. Enter only inserts, it
    // never sends; other keys take back the preview and go to the app.
    static func panelKey(_ keyCode: UInt16) -> PanelKey? {
        switch keyCode {
        case 36, 76, 48: return .accept // Return, keypad Enter, Tab: the highlighted row
        case 18, 83: return .choose(0)
        case 19, 84: return .choose(1)
        case 20, 85: return .choose(2)
        case 125: return .move(1)
        case 126: return .move(-1)
        case 53, 51: return .dismiss // Esc; Backspace takes back the preview
        default: return nil
        }
    }
    static let fieldMarker = "[输入框]"
    static let maximumSuggestions = 3
    static let maximumLength = 60

    // Keeps the text nearest the field: the tail of what precedes it and a little
    // of what follows. `after == nil` means the field's position is unknown.
    static func excerpt(before: [String], after: [String]?, limit: Int = 1000) -> String {
        func clean(_ lines: [String]) -> [String] {
            var result: [String] = []
            for line in lines {
                let text = String(line.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
                if !text.isEmpty, text != result.last { result.append(text) }
            }
            return result
        }
        var head: [String] = [], used = 0
        for line in clean(before).reversed() {
            guard used + line.count <= (after == nil ? limit : limit * 4 / 5) else { break }
            head.insert(line, at: 0); used += line.count + 1
        }
        guard let after else { return head.joined(separator: "\n") }
        var tail: [String] = []
        for line in clean(after) {
            guard used + line.count <= limit else { break }
            tail.append(line); used += line.count + 1
        }
        return (head + [fieldMarker] + tail).joined(separator: "\n")
    }

    // Text inside photos, video thumbnails and pasted screenshots is much smaller than
    // the app's own text, and OCR reads it too.
    static func dropSmallText(_ items: [ScreenItem]) -> [ScreenItem] {
        let heights = items.map(\.frame.height).sorted()
        guard !heights.isEmpty else { return items }
        return items.filter { $0.frame.height >= heights[heights.count / 2] * 0.65 }
    }

    // Lays out what was read the way the user sees it. Keeps the column the field is in
    // (chat apps put the conversation above the input box and the chat list beside it),
    // in reading order, and marks each line's side: in chat apps ← is usually someone
    // else and → the user. Text level with the field is left out; what is before the
    // cursor is sent separately. Text in the window's header becomes the title.
    static func arrange(_ items: [ScreenItem], field: CGRect?, window: CGRect, limit: Int = 1000) -> (title: String, text: String) {
        let rows = items.filter { $0.frame.intersects(window) && $0.text.unicodeScalars.contains { CharacterSet.letters.contains($0) } }
            .sorted { ($0.frame.minY / 8).rounded(.down) != ($1.frame.minY / 8).rounded(.down)
                ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
        guard let field, window.contains(CGPoint(x: field.minX, y: field.midY)) else {
            return ("", excerpt(before: rows.map(\.text), after: nil, limit: limit))
        }
        // The field's column reaches left through text that overlaps its left edge without a
        // clear gap (messages often start left of the input box); a chat list stays out.
        var left = field.minX
        let above = rows.filter { $0.frame.minY > window.minY + 56 && $0.frame.maxY < field.minY }
        while let reach = above.filter({ $0.frame.minX < left && $0.frame.maxX > left - 12 }).map(\.frame.minX).min() { left = reach }
        left -= 12
        let body = rows.filter { $0.frame.minX >= left }
        let header = body.filter { $0.frame.maxY <= window.minY + 56 && $0.frame.maxY < field.minY }
        let width = max(1, window.maxX - left)
        func marked(_ item: ScreenItem) -> String {
            let leading = item.frame.minX - left, trailing = window.maxX - item.frame.maxX
            let side = item.frame.width > width * 0.8 || leading < trailing - width * 0.15 ? "←"
                : trailing < leading - width * 0.15 ? "→" : "·"
            return side + " " + item.text
        }
        let rest = body.filter { !header.contains($0) }
        return (header.map(\.text).joined(separator: " "),
                excerpt(before: rest.filter { $0.frame.midY < field.minY }.map(marked),
                        after: rest.filter { $0.frame.midY > field.maxY }.map(marked), limit: limit))
    }

    // Model output becomes text inserted at the caret: one line each, no numbering
    // or quotes, never a repeat of what is already before the cursor, and never text
    // mostly copied from one screen line, such as a chat name or someone's message
    // (the small model sometimes echoes them).
    static func accept(_ raw: [String], precedingText: String, screen: String = "") -> [String] {
        let shown = screen.components(separatedBy: .newlines).map { Array($0.filter { !$0.isWhitespace }) }
        var result: [String] = []
        for item in raw {
            var text = item.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if let range = text.range(of: #"^(\d+[.)、．]|[-•*])\s*"#, options: .regularExpression) { text.removeSubrange(range) }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’「」『』").union(.whitespaces))
            let typed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let overlap = stride(from: min(typed.count, text.count), through: 2, by: -1)
                .first(where: { text.hasPrefix(typed.suffix($0)) }) {
                text = String(text.dropFirst(overlap)).trimmingCharacters(in: .whitespaces)
            }
            let letters = Array(text.filter { !$0.isWhitespace })
            guard !text.isEmpty, text.count <= maximumLength, !result.contains(text),
                  !shown.contains(where: { longestCommonRun(letters, $0) >= max(4, letters.count * 3 / 5) }) else { continue }
            result.append(text)
            if result.count == maximumSuggestions { break }
        }
        return result
    }
    private static func longestCommonRun(_ a: [Character], _ b: [Character]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1), best = 0
        for x in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() where x == y {
                current[j + 1] = previous[j] + 1
                best = max(best, current[j + 1])
            }
            previous = current
        }
        return best
    }
}
