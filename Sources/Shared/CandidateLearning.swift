import Foundation

// Supplements Rime's own learning when a cloud ranking would otherwise replace
// it. Keys are exact spellings, not surrounding text or application identities.
struct CandidateLearning: Codable {
    struct Choice: Codable {
        var count: Int
        var lastUsed: Date
    }
    private(set) var spellings: [String: [String: Choice]] = [:]
    static let maximumSpellings = 2048
    static let maximumChoices = 8

    private static func validSpelling(_ spelling: String) -> Bool {
        (1...64).contains(spelling.utf8.count) &&
        spelling.utf8.allSatisfy { (97...122).contains($0) || $0 == 39 }
    }

    @discardableResult
    mutating func record(spelling: String, commit: String, at date: Date = Date()) -> Bool {
        // Punctuation can implicitly accept the highlighted word. Ignore its
        // trailing punctuation, but never learn raw Latin text or mixed input.
        let word = commit.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        guard Self.validSpelling(spelling), (1...24).contains(word.count),
              word.unicodeScalars.allSatisfy(\.properties.isIdeographic) else { return false }
        var choices = spellings[spelling] ?? [:]
        var choice = choices[word] ?? Choice(count: 0, lastUsed: date)
        choice.count = min(max(choice.count, 0), 1_000_000) + 1
        choice.lastUsed = date
        choices[word] = choice
        if choices.count > Self.maximumChoices {
            let oldest = choices.filter { $0.key != word }.min { $0.value.lastUsed < $1.value.lastUsed }
            if let oldest { choices.removeValue(forKey: oldest.key) }
        }
        spellings[spelling] = choices
        if spellings.count > Self.maximumSpellings {
            let oldest = spellings.filter { $0.key != spelling }.min {
                ($0.value.values.map(\.lastUsed).max() ?? .distantPast) <
                ($1.value.values.map(\.lastUsed).max() ?? .distantPast)
            }
            if let oldest { spellings.removeValue(forKey: oldest.key) }
        }
        return true
    }

    func choices(for spelling: String) -> [String: Choice] { spellings[spelling] ?? [:] }
}

// One instance shared by input clients. Memory changes immediately; only the
// bounded file snapshot is written on the serial background queue.
final class CandidateLearningStore {
    static let shared = CandidateLearningStore()
    static var url: URL { LocalPaths.root.appendingPathComponent("candidate-learning.json") }
    private(set) var learning: CandidateLearning
    private let url: URL
    private let queue = DispatchQueue(label: "org.localinput.candidate-learning", qos: .utility)
    private var pending: DispatchWorkItem?

    init(url: URL = CandidateLearningStore.url) {
        self.url = url
        learning = LocalPaths.read(CandidateLearning.self, from: url) ?? CandidateLearning()
    }

    func record(spelling: String, commit: String, at date: Date = Date()) {
        guard learning.record(spelling: spelling, commit: commit, at: date) else { return }
        pending?.cancel()
        let work = saveWork()
        pending = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flush(wait: Bool = false) {
        guard pending != nil else {
            if wait { queue.sync {} }
            return
        }
        pending?.cancel(); pending = nil
        let work = saveWork()
        if wait { queue.sync { work.perform() } } else { queue.async(execute: work) }
    }

    private func saveWork() -> DispatchWorkItem {
        let snapshot = learning, url = url
        return DispatchWorkItem {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try LocalPaths.write(snapshot, to: url)
            } catch {
                // Keep the in-memory preference; the next accepted word retries.
            }
        }
    }
}
