import Foundation

@main struct WordStatsTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)

        // Sentences are split into words; numbers, emoji and punctuation are dropped.
        check(WordStats.words(in: "今天天气很好") == ["今天", "天气", "很", "好"], "Chinese sentence segmentation")
        check(WordStats.words(in: "我用iPhone发邮件，价格是199元。😀") == ["我", "用", "iPhone", "发", "邮件", "价格", "是", "元"],
              "mixed text without numbers, emoji or punctuation")
        check(WordStats.words(in: "，。！").isEmpty && WordStats.words(in: "  ").isEmpty, "nothing to count")
        // A short picked candidate is one word even when the tokenizer would split it.
        check(WordStats.words(in: "显眼包", isPick: true) == ["显眼包"], "picked slang stays whole")
        check(WordStats.words(in: "显眼包") != ["显眼包"], "tokenizer alone splits the slang")
        check(WordStats.words(in: "情绪价值", isPick: true) == ["情绪", "价值"], "longer commits are segmented")
        check(WordStats.words(in: "。", isPick: true).isEmpty, "picked punctuation is not a word")
        // The user's own terms are rejoined.
        check(WordStats.words(in: "显眼包来了", vocabulary: ["显眼包"]).first == "显眼包", "vocabulary term rejoined")
        check(WordStats.words(in: "我用轻言输入", vocabulary: ["轻言"]).contains("轻言"), "product term rejoined")

        var stats = WordStats()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        stats.add(["你好", "世界"], source: .typed, at: day)
        stats.add(["你好"], source: .voice, at: day.addingTimeInterval(60))
        check(stats.words["你好"] == WordStats.Entry(typed: 1, voice: 1, last: day.addingTimeInterval(60)), "per-source counts and last use")
        check(stats.words["世界"]?.total == 1, "total")
        check(stats.days[WordStats.day(day)] == 3, "daily word count")
        stats.add([], source: .typed, at: day.addingTimeInterval(86_400 * 3))
        check(stats.days.count == 1, "an empty commit adds no day")

        // Batches are merged into the file, which is owner-only and survives restarts.
        let url = scratch.appendingPathComponent("word-stats.json")
        let recorder = WordStatsRecorder(url: url, delay: 3600)
        recorder.record("今天天气很好", source: .voice, vocabulary: "")
        recorder.record("显眼包", source: .typed, vocabulary: "")
        recorder.record("", source: .typed, vocabulary: "")
        recorder.flush(wait: true)
        var saved = WordStats.load(from: url)
        check(saved?.words["显眼包"]?.typed == 1 && saved?.words["天气"]?.voice == 1, "batch written")
        check(saved?.words.values.reduce(0) { $0 + $1.total } == 5, "only real words counted")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        check(mode?.int16Value == 0o600, "statistics are owner-only")
        recorder.record("今天", source: .typed, vocabulary: "")
        WordStatsRecorder(url: url, delay: 3600).flush(wait: true)
        recorder.flush(wait: true)
        saved = WordStats.load(from: url)
        check(saved?.words["今天"] == WordStats.Entry(typed: 1, voice: 1, last: saved?.words["今天"]?.last ?? .distantPast),
              "a later batch adds to the stored counts")
        // Clearing in settings deletes the file; memory must not bring old counts back.
        try FileManager.default.removeItem(at: url)
        recorder.record("你好", source: .typed, vocabulary: "")
        recorder.flush(wait: true)
        saved = WordStats.load(from: url)
        check(saved?.words.keys.sorted() == ["你好"], "cleared counts stay cleared")
        recorder.flush(wait: true)
        check(WordStats.load(from: url) == saved, "an empty flush changes nothing")

        // Recording is opt-in; old settings files keep it off.
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"jevEnabled":true}"#.utf8))
        check(!old.wordStatsEnabled && old.jevEnabled, "missing key means off")
        var on = Settings(); on.wordStatsEnabled = true
        check(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(on)).wordStatsEnabled, "setting round-trips")

        print("PASS: word segmentation, picked words, vocabulary, counts, batched file writes, clearing and opt-in setting")
    }
}
