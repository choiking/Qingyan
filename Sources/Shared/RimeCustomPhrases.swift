import Foundation

// The 常用词 list was only reaching Whisper's decoder. The same homophone problem
// exists when those words are typed, so the list is also written out as Rime's
// custom phrase table. luna_pinyin already runs a `custom_phrase` table
// translator over <user dir>/custom_phrase.txt with initial_quality 1, and reads
// that file when a session is created — no dictionary rebuild is involved.
enum RimeCustomPhrases {
    // Kept small: every extra code is one more spelling that resolves to a user
    // term ahead of the dictionary's own candidates.
    static let maximumCodesPerTerm = 4
    static let maximumReadingsPerCharacter = 3
    static let minimumReadingShare = 5.0
    static let maximumTermCharacters = 12
    static let fileName = "custom_phrase.txt"
    static let stampName = "custom_phrase.stamp"

    struct Reading {
        let code: String
        let share: Double
    }

    static func isHan(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: return true
        default: return false
        }
    }

    // Rime dictionaries are tab separated: text, code, then an optional weight
    // that luna_pinyin writes as a share ("91.78%") for characters with several
    // readings. Only single-character rows for `characters` are kept, so the
    // 2 MB dictionary is scanned as bytes instead of being turned into a String.
    static func readings(dictionaryAt url: URL, for characters: Set<Character>) -> [Character: [Reading]] {
        guard !characters.isEmpty, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
        var collected: [Character: [Reading]] = [:]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                parse(bytes, from: start, to: end, characters: characters, into: &collected)
                start = end + 1
            }
        }
        for (character, list) in collected {
            // Most likely reading first; ties keep dictionary order.
            let sorted = list.enumerated().sorted {
                $0.element.share == $1.element.share ? $0.offset < $1.offset : $0.element.share > $1.element.share
            }.map(\.element)
            let kept = sorted.enumerated().filter { $0.offset == 0 || $0.element.share >= minimumReadingShare }
            collected[character] = Array(kept.map(\.element).prefix(maximumReadingsPerCharacter))
        }
        return collected
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int,
                              characters: Set<Character>, into collected: inout [Character: [Reading]]) {
        guard start < end, bytes[start] != 0x23 else { return }  // '#'
        var first = start
        while first < end, bytes[first] != 0x09 { first += 1 }   // tab
        guard first < end, first - start <= 4,
              let text = string(bytes, start, first), text.count == 1,
              let character = text.first, characters.contains(character) else { return }
        var second = first + 1
        while second < end, bytes[second] != 0x09 { second += 1 }
        guard let code = string(bytes, first + 1, second), !code.isEmpty,
              code.allSatisfy({ $0.isLowercase && $0.isASCII }) else { return }
        var share = 100.0
        if second < end, let weight = string(bytes, second + 1, end) {
            let trimmed = weight.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("%"), let value = Double(trimmed.dropLast()) { share = value }
        }
        collected[character, default: []].append(Reading(code: code, share: share))
    }

    private static func string(_ bytes: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int) -> String? {
        guard from <= to, let base = bytes.baseAddress else { return nil }
        return String(bytes: UnsafeBufferPointer(start: base + from, count: to - from), encoding: .utf8)
    }

    // Spellings for one term, most likely first. Empty when the term is not all
    // Han characters or when any character has no known reading: a term without
    // a complete code cannot be typed, and a partial code would be wrong.
    static func codes(for term: String, readings: [Character: [Reading]]) -> [String] {
        let characters = Array(term)
        guard !characters.isEmpty, characters.count <= maximumTermCharacters,
              characters.allSatisfy(isHan) else { return [] }
        var combinations: [(code: String, likelihood: Double)] = [("", 1)]
        for character in characters {
            guard let choices = readings[character], !choices.isEmpty else { return [] }
            combinations = combinations.flatMap { prefix in
                choices.map { (prefix.code + $0.code, prefix.likelihood * max($0.share, 0.01)) }
            }
            combinations.sort { $0.likelihood > $1.likelihood }
            combinations = Array(combinations.prefix(maximumCodesPerTerm))
        }
        return combinations.map(\.code)
    }

    static func table(for terms: [String], readings: [Character: [Reading]]) -> String {
        var lines = ["# Generated by Qingyan from the 常用词 list. Edits here are overwritten."]
        for term in terms {
            for (index, code) in codes(for: term, readings: readings).enumerated() {
                // The most likely spelling outranks the alternate readings of the same term.
                lines.append("\(term)\t\(code)\t\(index == 0 ? 2 : 1)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // A cheap stamp so the dictionary is only scanned when the list really changed.
    static func stamp(for terms: [String]) -> String { terms.joined(separator: "\n") }

    // True when the table was rewritten, which means open sessions have to be replaced.
    @discardableResult
    static func sync(vocabulary: String, dictionaryAt dictionary: URL, userDirectory: URL) -> Bool {
        let terms = VoiceVocabulary.normalize(vocabulary)
        let tableURL = userDirectory.appendingPathComponent(fileName)
        let stampURL = userDirectory.appendingPathComponent(stampName)
        let wanted = stamp(for: terms)
        if let current = try? String(contentsOf: stampURL, encoding: .utf8), current == wanted,
           FileManager.default.fileExists(atPath: tableURL.path) { return false }
        var characters = Set<Character>()
        for term in terms where term.count <= maximumTermCharacters { characters.formUnion(term) }
        let content = table(for: terms, readings: readings(dictionaryAt: dictionary, for: characters.filter(isHan)))
        do {
            // The word list is personal data, so both files stay owner-only like the rest of the directory.
            try write(content, to: tableURL)
            try write(wanted, to: stampURL)
        } catch { return false }
        return true
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
