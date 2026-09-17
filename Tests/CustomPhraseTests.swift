import Foundation

@main struct CustomPhraseTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        let dictionary = URL(fileURLWithPath: CommandLine.arguments[1])
        let scratch = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        // Readings come from the shipped dictionary, most likely first, and cover the
        // simplified characters a user actually types even though the vocabulary itself
        // is traditional.
        let wanted: Set<Character> = ["张", "伟", "重", "行", "的", "轻", "言", "南", "生"]
        let readings = RimeCustomPhrases.readings(dictionaryAt: dictionary, for: wanted)
        check(readings["张"]?.map(\.code) == ["zhang"], "single reading character")
        check(readings["重"]?.map(\.code) == ["zhong", "chong"], "polyphone ordered by share, not dictionary order")
        check(readings["行"]?.map(\.code) == ["xing", "hang"], "dominant reading first")
        check(readings["的"]?.map(\.code) == ["de"], "readings below the share floor are dropped")
        check(readings.count == wanted.count, "every requested character resolved")
        check(RimeCustomPhrases.readings(dictionaryAt: dictionary, for: []).isEmpty, "no characters means no scan")

        check(RimeCustomPhrases.codes(for: "张伟", readings: readings) == ["zhangwei"], "name spelled from its characters")
        check(RimeCustomPhrases.codes(for: "轻言", readings: readings) == ["qingyan"], "product term")
        let heavy = RimeCustomPhrases.codes(for: "重行", readings: readings)
        check(heavy.first == "zhongxing", "most likely combination leads")
        check(heavy.count <= RimeCustomPhrases.maximumCodesPerTerm, "alternate spellings are capped")
        check(Set(heavy).count == heavy.count, "no duplicate codes")

        // A term that cannot be spelled completely must not produce a partial code.
        check(RimeCustomPhrases.codes(for: "Qingyan", readings: readings).isEmpty, "latin terms are skipped")
        check(RimeCustomPhrases.codes(for: "AI眼镜", readings: readings).isEmpty, "mixed terms are skipped")
        check(RimeCustomPhrases.codes(for: "轻言🙂", readings: readings).isEmpty, "emoji are skipped")
        check(RimeCustomPhrases.codes(for: "", readings: readings).isEmpty, "empty term")
        check(RimeCustomPhrases.codes(for: "张伟", readings: [:]).isEmpty, "unknown characters yield nothing")
        check(RimeCustomPhrases.codes(for: String(repeating: "张", count: 13), readings: readings).isEmpty,
              "over-long terms are skipped rather than spelled")

        let table = RimeCustomPhrases.table(for: ["南生", "Qingyan", "重行"], readings: readings)
        let rows = table.split(separator: "\n").filter { !$0.hasPrefix("#") }
        check(rows.contains("南生\tnansheng\t2"), "table row carries text, code and weight")
        check(!rows.contains { $0.hasPrefix("Qingyan") }, "unspellable terms leave no row")
        check(rows.contains("重行\tzhongxing\t2") && rows.contains { $0.hasPrefix("重行\tchong") && $0.hasSuffix("\t1") },
              "primary spelling outweighs alternates")
        check(table.hasSuffix("\n"), "trailing newline")

        // Syncing writes the table once and reports whether sessions must be replaced.
        check(RimeCustomPhrases.sync(vocabulary: "南生\n轻言", dictionaryAt: dictionary, userDirectory: scratch),
              "first sync writes the table")
        check(!RimeCustomPhrases.sync(vocabulary: "南生\n轻言", dictionaryAt: dictionary, userDirectory: scratch),
              "an unchanged list is not rewritten")
        check(RimeCustomPhrases.sync(vocabulary: "南生", dictionaryAt: dictionary, userDirectory: scratch),
              "a changed list is rewritten")
        let written = scratch.appendingPathComponent(RimeCustomPhrases.fileName)
        let contents = try String(contentsOf: written, encoding: .utf8)
        check(contents.contains("南生\tnansheng\t2") && !contents.contains("轻言"), "the table matches the current list")
        let mode = try FileManager.default.attributesOfItem(atPath: written.path)[.posixPermissions] as? NSNumber
        check(mode?.int16Value == 0o600, "the generated word list is owner-only")
        try FileManager.default.removeItem(at: written)
        check(RimeCustomPhrases.sync(vocabulary: "南生", dictionaryAt: dictionary, userDirectory: scratch),
              "a missing table is regenerated even when the stamp matches")

        print("PASS: custom phrase readings, spelling, capped alternates, table rows, sync and permissions")
    }
}
