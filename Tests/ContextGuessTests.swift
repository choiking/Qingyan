import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("FAIL: \(message)") }
}

@main struct ContextGuessTests {
    static func main() throws {
        let legacy = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        check(!legacy.contextGuessEnabled, "existing installations do not read the screen by default")
        check(legacy.contextSource == ContextSource.auto.rawValue, "default source reads interface text first")
        var settings = Settings(); settings.contextGuessEnabled = true; settings.contextSource = ContextSource.screenshot.rawValue
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        check(restored.contextGuessEnabled && restored.contextSource == "screenshot", "guess preferences round trip")
        check(legacy.guessShortcut == .defaultGuessShortcut && legacy.guessShortcut.displayName == "⌃⌥G", "guessing waits for ⌃⌥G by default")
        check(legacy.guessShortcut != legacy.voiceShortcut, "default guess and voice keys differ")
        settings.guessShortcut = VoiceShortcut(keyCode: 96, modifiers: 0)
        let customKey = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        check(customKey.guessShortcut.displayName == "F5", "custom guess key round trips")
        settings.guessShortcut = VoiceShortcut(keyCode: 61, modifiers: 0, trigger: .modifierPress)
        let modifierKey = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        check(modifierKey.guessShortcut == .defaultGuessShortcut && modifierKey.contextGuessEnabled,
              "a held-modifier guess key falls back without resetting other settings")
        check(VoiceShortcut.defaultGuessShortcut.matches(keyCode: 5, flags: [.control, .option, .function]) &&
              !VoiceShortcut.defaultGuessShortcut.matches(keyCode: 5, flags: [.control]), "only the exact chord triggers a guess")

        let request = ContextRequest(id: UUID(), pid: 42, precedingText: "你好 👋", caret: CGRect(x: 10, y: 20, width: 1, height: 18), created: Date())
        let decoded = try JSONDecoder().decode(ContextRequest.self, from: JSONEncoder().encode(request))
        check(decoded.id == request.id && decoded.pid == 42 && decoded.precedingText == "你好 👋" && decoded.caret == request.caret, "IPC request round trip")
        let reply = ContextReply(phase: "ready", suggestions: ["好的", "OK"])
        let replyCopy = try JSONDecoder().decode(ContextReply.self, from: JSONEncoder().encode(reply))
        check(replyCopy == reply, "IPC reply round trip")
        let sourced = ContextReply(phase: "ready", suggestions: ["好的"], source: "截图识别")
        let sourcedCopy = try JSONDecoder().decode(ContextReply.self, from: JSONEncoder().encode(sourced))
        check(sourcedCopy.source == "截图识别", "reply names its source")
        let olderReply = try JSONDecoder().decode(ContextReply.self, from: Data(#"{"phase":"ready","suggestions":["好的"],"detail":""}"#.utf8))
        check(olderReply.source == nil && olderReply.suggestions == ["好的"], "a reply from an older helper still decodes")

        check([36, 76, 48].allSatisfy { ContextGuess.panelKey($0) == .accept }, "Return, keypad Enter and Tab insert the highlighted suggestion")
        check(ContextGuess.panelKey(18) == .choose(0) && ContextGuess.panelKey(19) == .choose(1) && ContextGuess.panelKey(85) == .choose(2),
              "1–3 insert that row")
        check(ContextGuess.panelKey(125) == .move(1) && ContextGuess.panelKey(126) == .move(-1), "↑↓ move the highlight")
        check(ContextGuess.panelKey(53) == .dismiss && ContextGuess.panelKey(51) == .dismiss, "Esc and Backspace take the preview back")
        check([123, 124, 0, 49, 21].allSatisfy { ContextGuess.panelKey($0) == nil }, "←→, letters, space and 4 close the panel and reach the app")

        // Excerpt keeps what is nearest the field and marks where it is.
        let chat = ContextGuess.excerpt(before: ["李雷", "  周六下午  有空吗？ ", "周六下午 有空吗？", ""], after: ["发送"])
        check(chat == "李雷\n周六下午 有空吗？\n[输入框]\n发送", "whitespace collapsed, repeats and blanks dropped: \(chat)")
        let long = (0..<100).map { "第\($0)条消息" }
        let tail = ContextGuess.excerpt(before: long, after: nil, limit: 60)
        check(tail.hasSuffix("第99条消息") && !tail.contains("第0条消息") && tail.count <= 60, "keeps the most recent text: \(tail)")
        check(!tail.contains(ContextGuess.fieldMarker), "unknown field position has no marker")
        let bounded = ContextGuess.excerpt(before: long, after: long, limit: 100)
        check(bounded.contains("第99条消息\n[输入框]\n第0条消息") && bounded.count <= 100 + ContextGuess.fieldMarker.count + 1,
              "text after the field fills the remaining budget: \(bounded)")
        check(ContextGuess.excerpt(before: [String(repeating: "长", count: 500)], after: nil).count == 200, "one line cannot take the whole budget")

        // Suggestions become text inserted at the caret.
        let cleaned = ContextGuess.accept(["1. 好的，我周六有空", "“可以，一起打球”", "好的，我周六有空", "", "第三条\n换行", "第四条"], precedingText: "")
        check(cleaned == ["好的，我周六有空", "可以，一起打球", "第三条 换行"], "numbering, quotes, duplicates, blanks and newlines: \(cleaned)")
        check(ContextGuess.accept(["王总，您好：收到，我周五前确认", "收到"], precedingText: "王总，您好：\n") == ["收到，我周五前确认", "收到"],
              "typed text is not repeated")
        check(ContextGuess.accept(["牛奶、鸡蛋、面包"], precedingText: "牛奶、鸡蛋、") == ["面包"], "overlap with the typed tail is dropped")
        check(ContextGuess.accept(["想吃火锅"], precedingText: "我想") == ["想吃火锅"], "a single shared character is not treated as a repeat")
        check(ContextGuess.accept([String(repeating: "长", count: ContextGuess.maximumLength + 1)], precedingText: "").isEmpty, "overlong lines are dropped")
        let screen = "李雷 14:02\n周六下午有空吗？一起去打羽毛球吧\n[输入框]\n发送"
        check(ContextGuess.accept(["周六下午有空吗？ 一起去打羽毛球吧", "好的，我周六有空", "发送"], precedingText: "", screen: screen) == ["好的，我周六有空", "发送"],
              "a copied message is dropped; short common words are kept")
        check(ContextGuess.accept(["A", "B", "C", "D"], precedingText: "").count == ContextGuess.maximumSuggestions, "at most three suggestions")
        // A chat window: chat list on the left, conversation above the input box on the right.
        func item(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat = 16) -> ScreenItem {
            ScreenItem(text: text, frame: CGRect(x: x, y: y, width: w, height: h))
        }
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let layout = [
            item("群聊名称（5）", 370, 20, 100), item("…•<", 870, 20, 30, 12),
            item("某个群", 130, 70, 80), item("张三：[Photo]", 130, 90, 100, 14), item("Yesterday 22:00", 620, 80, 100, 14),
            item("这个想法很有意思", 800, 290, 110, 18), item("另一个群", 130, 300, 80),
            item("Yiyi", 425, 380, 30, 14), item("不错", 435, 400, 30, 18), item("招聘群：内推", 130, 410, 90),
            item("已输入的文字", 380, 700, 90), item("发送", 930, 760, 30, 14),
        ]
        let caretLine = CGRect(x: 372, y: 700, width: 1, height: 18)
        let arranged = ContextGuess.arrange(layout, field: caretLine, window: window)
        check(arranged.title == "群聊名称（5）", "header becomes the title: \(arranged.title)")
        check(arranged.text == "· Yesterday 22:00\n→ 这个想法很有意思\n← Yiyi\n← 不错\n[输入框]\n→ 发送",
              "only the input box's column, sides marked, the field's own row and symbols left out: \(arranged.text)")
        let unplaced = ContextGuess.arrange(layout, field: nil, window: window)
        check(unplaced.title.isEmpty && unplaced.text.contains("某个群") && !unplaced.text.contains("[输入框]") && !unplaced.text.contains("←"),
              "without a caret the whole window is read in order: \(unplaced.text)")
        check(ContextGuess.arrange([item("左栏", 10, 100, 40)], field: caretLine, window: window).text == "[输入框]",
              "nothing in the column means nothing above the field")
        let bubbles = ContextGuess.arrange([item("对方的消息", 360, 300, 200), item("会话列表", 100, 300, 150)],
                                           field: CGRect(x: 420, y: 700, width: 1, height: 18), window: window)
        check(bubbles.text == "← 对方的消息\n[输入框]", "messages starting left of the input box stay in its column: \(bubbles.text)")
        let offscreen = ContextGuess.arrange([item("看不见", 400, -300, 60), item("看得见", 400, 300, 60)], field: caretLine, window: window)
        check(offscreen.text == "← 看得见\n[输入框]", "text scrolled out of the window is not read")
        let pasted = ContextGuess.dropSmallText([item("消息", 400, 100, 60, 16), item("消息二", 400, 140, 60, 18), item("正文", 400, 180, 60, 16),
                                                item("截图里的小字", 700, 300, 60, 7), item("缩略图文字", 700, 320, 60, 6)])
        check(pasted.map(\.text) == ["消息", "消息二", "正文"], "text inside pictures is dropped")
        let sidebar = "群聊名称（5）\n去@当Q最幸福：天龙人专用\n亚马逊社招求职内…"
        check(ContextGuess.accept(["群聊名称等", "去@当Q最幸福", "亚马逊社招求职内", "哈哈，谢谢支持"], precedingText: "", screen: sidebar) == ["哈哈，谢谢支持"],
              "chat names copied from the screen are dropped")
        print("PASS: 猜你想说 settings and shortcut, IPC, context excerpt, screen layout and suggestion cleanup")
    }
}
