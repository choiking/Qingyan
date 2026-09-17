import Foundation

@main struct CorrectionTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"language":"en","fontSize":22,"shiftToggle":false,"modelPath":"custom"}"#.utf8))
        check(!old.correctionEnabled && old.voiceVocabulary == "轻言\nQingyan" && old.language == "en" && old.fontSize == 22 && !old.shiftToggle, "migration preserves preferences and leaves optional AI off")
        var settings = old
        settings.correctionEnabled = true; settings.voiceVocabulary = "轻言\nQingyan\n南生"
        let roundtrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        check(roundtrip.correctionEnabled && roundtrip.voiceVocabulary == settings.voiceVocabulary, "settings roundtrip")
        check(VoiceVocabulary.normalize("  轻言 \nQingyan\nqingyan\n\n轻言") == ["轻言", "Qingyan"], "vocabulary trimming and deduplication")
        check(VoiceVocabulary.normalize(String(repeating: "字", count: 41)).isEmpty, "oversize term excluded")
        check(VoiceVocabulary.normalize((0..<100).map { "term\($0)" }.joined(separator: "\n")).count == 40, "bounded prompt")
        let legacyReply = try JSONDecoder().decode(VoiceReply.self, from: Data(#"{"phase":"ready","text":"你好","detail":"完成"}"#.utf8))
        check(legacyReply.originalText == nil, "old replies remain compatible")
        let reply = VoiceReply(phase: "correcting", text: "青年输入法", detail: "", originalText: "青年输入法")
        check(try JSONDecoder().decode(VoiceReply.self, from: JSONEncoder().encode(reply)) == reply, "correction IPC roundtrip")
        func accepted(_ raw: String, _ corrected: String) -> Bool { CorrectionPolicy.accept(original: raw, candidate: corrected, vocabulary: "轻言\nQingyan") != nil }
        check(accepted("欢迎使用青年输入法。", "欢迎使用轻言输入法。"), "small homophone correction")
        check(accepted("Hello world", "Hello, world."), "punctuation")
        check(!accepted("明天 15:30 付款 2500 元。", "明天 15:30 付款 250 元。"), "amount protected")
        check(!accepted("温度 -10 度。", "温度 10 度。"), "number sign protected")
        check(!accepted("Send five dollars.", "Send six dollars."), "English number words protected")
        check(!accepted("三点开会。", "四点开会。"), "Chinese number protected")
        check(!accepted("请不要提交。", "请提交。"), "negation protected")
        check(!accepted("Do not send it.", "Do send it."), "English negation protected")
        check(!accepted("使用 Qingyan。", "使用 Qingyon。"), "known name protected")
        check(!accepted("你好。", "以下是经过润色的文字：您好，很高兴认识您！"), "expansion rejected")
        check(!accepted("你好。", ""), "empty rejected")
        check(!accepted("你好。", "你好。\n再见。"), "extra line rejected")
        print("PASS: correction settings migration, vocabulary limits, IPC compatibility, conservative correction and protected facts")
    }
}
