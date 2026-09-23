import Foundation
import NaturalLanguage

// Per-word totals of committed text for the statistics tab. Only counts are kept:
// no sentences, word order or application names.
struct WordStats: Codable, Equatable {
    enum Source { case typed, voice }
    struct Entry: Codable, Equatable {
        var typed = 0
        var voice = 0
        var last = Date.distantPast
        var total: Int { typed + voice }
    }
    var since = Date()
    var words: [String: Entry] = [:]
    // Local calendar day (yyyy-MM-dd) → words recorded that day.
    var days: [String: Int] = [:]

    static var url: URL { LocalPaths.root.appendingPathComponent("word-stats.json") }
    static func load(from url: URL = url) -> WordStats? { LocalPaths.read(Self.self, from: url) }

    static func words(in text: String, isPick: Bool = false, vocabulary: Set<String> = []) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A short typed commit is the word picked from the candidates; the system
        // tokenizer does not know slang such as 显眼包 and would split it.
        if isPick, (1...3).contains(text.count), text.unicodeScalars.allSatisfy(\.properties.isIdeographic) { return [text] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        var result: [String] = []
        var i = 0
        while i < ranges.count {
            // Rejoin the user's own terms (常用词), which the tokenizer splits.
            var end = i
            for j in stride(from: min(i + 5, ranges.count - 1), to: i, by: -1)
            where vocabulary.contains(String(text[ranges[i].lowerBound..<ranges[j].upperBound])) { end = j; break }
            result.append(String(text[ranges[i].lowerBound..<ranges[end].upperBound]))
            i = end + 1
        }
        // Numbers, emoji and punctuation are not words.
        return result.filter { $0.unicodeScalars.contains { CharacterSet.letters.contains($0) } }
    }
    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    mutating func add(_ words: [String], source: Source, at date: Date) {
        guard !words.isEmpty else { return }
        for word in words {
            var entry = self.words[word] ?? Entry()
            if source == .voice { entry.voice += 1 } else { entry.typed += 1 }
            entry.last = max(entry.last, date)
            self.words[word] = entry
        }
        days[Self.day(date), default: 0] += words.count
    }
}

// Commits arrive on the main thread; tokenizing and disk writes are batched off it.
// Each flush re-reads the file, so clearing it from settings is not undone by memory.
final class WordStatsRecorder {
    static let shared = WordStatsRecorder()
    let url: URL
    private let delay: TimeInterval
    private let queue = DispatchQueue(label: "org.localinput.word-stats", qos: .utility)
    private var pending: [(text: String, source: WordStats.Source, date: Date)] = []
    private var vocabulary = ""

    init(url: URL = WordStats.url, delay: TimeInterval = 2) { self.url = url; self.delay = delay }

    func record(_ text: String, source: WordStats.Source, vocabulary: String, at date: Date = Date()) {
        guard !text.isEmpty else { return }
        self.vocabulary = vocabulary
        pending.append((text, source, date))
        if pending.count == 1 { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.flush() } }
    }
    func flush(wait: Bool = false) {
        let batch = pending, url = url
        let terms = Set(VoiceVocabulary.normalize(vocabulary))
        pending = []
        guard !batch.isEmpty else { return }
        let work = {
            var stats = WordStats.load(from: url) ?? WordStats()
            for item in batch {
                stats.add(WordStats.words(in: item.text, isPick: item.source == .typed, vocabulary: terms),
                          source: item.source, at: item.date)
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? LocalPaths.write(stats, to: url)
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
}
