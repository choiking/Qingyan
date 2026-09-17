import Foundation

enum VoiceVocabulary {
    static func normalize(_ input: String) -> [String] {
        var seen = Set<String>()
        var totalCharacters = 0
        return input.components(separatedBy: .newlines).compactMap { line in
            let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 40, !term.unicodeScalars.contains(where: { $0.value < 32 }),
                  totalCharacters + term.count <= 400,
                  seen.insert(term.lowercased()).inserted else { return nil }
            totalCharacters += term.count
            return term
        }.prefix(40).map { $0 }
    }
    static func prompt(_ input: String) -> String { normalize(input).joined(separator: "、") }
}

// A second, deterministic boundary: the model is allowed only small edits.
// This cannot prove semantic equivalence; the original remains available.
enum CorrectionPolicy {
    static let maximumCharacters = 800
    static func accept(original: String, candidate: String, vocabulary: String) -> String? {
        let result = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, original.count <= maximumCharacters, result.count <= maximumCharacters,
              !result.contains("```"), !result.contains("<think>"),
              result.components(separatedBy: .newlines).count <= original.components(separatedBy: .newlines).count else { return nil }
        if result == original { return original }
        // Exact number sequences, dates, units and negation must survive even if plausible alternatives exist.
        let protected = #"[+−-]?[0-9０-９]+(?:[.,:/\-][0-9０-９]+)*|[零〇一二两三四五六七八九十百千万亿]+|不要|不是|不能|没有|不会|不|没|别|无|未|\b(?:not|no|never|without|can't|don't|won't)\b|\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion)\b|[%％℃¥$]|公斤|千克|公里|万元|亿元|美元|欧元|元"#
        func tokens(_ text: String) -> [String] {
            let expression = try! NSRegularExpression(pattern: protected, options: [.caseInsensitive])
            let string = text as NSString
            return expression.matches(in: text, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range).lowercased() }
        }
        guard tokens(original) == tokens(result) else { return nil }
        for term in VoiceVocabulary.normalize(vocabulary) where original.contains(term) {
            guard original.components(separatedBy: term).count == result.components(separatedBy: term).count else { return nil }
        }
        let lhs = Array(original), rhs = Array(result)
        var row = Array(0...rhs.count)
        for (i, a) in lhs.enumerated() {
            var next = [i + 1] + [Int](repeating: 0, count: rhs.count)
            for (j, b) in rhs.enumerated() { next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (a == b ? 0 : 1)) }
            row = next
        }
        guard row[rhs.count] <= min(12, max(2, original.count / 6)) else { return nil }
        return result
    }
}
