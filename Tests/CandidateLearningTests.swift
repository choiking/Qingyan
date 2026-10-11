import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("FAIL: \(message)") }
}

private func answer(_ value: Int) -> JevScore {
    JevScore(type: "score", score: Double(value),
        probabilities: Dictionary(uniqueKeysWithValues: (0...4).map { (String($0), $0 == value ? 1.0 : 0.0) }), confidence: 1)
}

@main struct CandidateLearningTests {
    static func main() throws {
        let args = CommandLine.arguments
        check(args.count == 4, "shared resources, scratch directory and phase required")
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let url = root.appendingPathComponent("candidate-learning.json")
        let store = CandidateLearningStore(url: url)
        let nativeUser = root.appendingPathComponent("Rime", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeUser, withIntermediateDirectories: true)
        LIRime.startShared(args[1], user: nativeUser.path, deploy: false)
        let engine = LIRime()
        check(engine.open(), "real Rime session opens")
        func type(_ spelling: String) { for key in spelling.utf8 { _ = engine.process(Int32(key), modifiers: 0) } }
        let day = Date(timeIntervalSince1970: 1_790_000_000)

        if args[3] == "learn" {
            var learning = CandidateLearning()
            check(learning.record(spelling: "youxiang", commit: "又想", at: day), "confirmed Chinese candidate is learned")
            check(learning.record(spelling: "youxiang", commit: "邮箱", at: day.addingTimeInterval(1)), "alternate choice is learned")
            let context = JevContext(precedingText: "", pinyin: "youxiang", preedit: "you xiang",
                candidates: ["油箱", "又想", "邮箱", "有"], coverageEnds: [8, 8, 8, 3])
            let cloud = try JevRanking(answers: ["c0": answer(4), "c1": answer(0), "c2": answer(1), "c3": answer(4)],
                candidateCount: 4, coverageEnds: context.coverageEnds)
            check(cloud.indices == [0, 2, 1, 3], "fixture reproduces cloud override of learned Rime order")
            check(cloud.applyingLearning(CandidateLearning(), context: context).indices == cloud.indices, "no history preserves cloud order")
            check(cloud.applyingLearning(learning, context: context).indices == [2, 1, 0, 3], "recent choice breaks equal-frequency ties")
            learning.record(spelling: "youxiang", commit: "又想", at: day.addingTimeInterval(2))
            let personalized = cloud.applyingLearning(learning, context: context)
            check(personalized.indices == [1, 2, 0, 3] && personalized.personalized, "repeated preference survives contrary cloud scores")
            check(personalized.scores == cloud.scores, "displayed Jev scores remain unmodified")
            learning.record(spelling: "youxiang", commit: "有", at: day)
            check(cloud.applyingLearning(learning, context: context).indices == [1, 2, 0, 3], "partial coverage cannot displace complete words")
            let other = JevContext(precedingText: "", pinyin: "you'xiang", preedit: "you xiang", candidates: context.candidates)
            check(cloud.applyingLearning(learning, context: other).indices == cloud.indices, "history is scoped to exact spelling including syllable boundaries")
            let remainder = JevContext(precedingText: "", pinyin: "youxiang", preedit: "有xiang", candidates: context.candidates)
            check(cloud.applyingLearning(learning, context: remainder).indices == cloud.indices, "whole-input preference never applies to remaining segment")
            for (spelling, text) in [("", "又想"), ("123", "又想"), ("hello", "hello"), ("youxiang", ""), ("youxiang", "有xiang"), ("a", "。") ] {
                check(!learning.record(spelling: spelling, commit: text), "raw input, cancellation and incomplete conversions are ignored")
            }
            check(learning.record(spelling: "youxiang", commit: "又想。", at: day), "implicit punctuation commit learns the word")
            var order = JevCandidateOrder(ranking: personalized, pageSize: 2)
            check(order.engineIndex(for: 0) == 1 && order.engineIndex(for: 1) == 2, "keys and clicks address the displayed personalized candidates")
            check(order.turnPage(1) && order.indices == [0, 3], "personalized paging has no duplicate or missing candidate")

            var bounded = CandidateLearning()
            for i in 0...CandidateLearning.maximumSpellings {
                let spelling = String(UnicodeScalar(97 + i / 676)!) + String(UnicodeScalar(97 + i / 26 % 26)!) + String(UnicodeScalar(97 + i % 26)!)
                bounded.record(spelling: spelling, commit: "词", at: day.addingTimeInterval(Double(i)))
            }
            check(bounded.spellings.count == CandidateLearning.maximumSpellings && bounded.choices(for: "aaa").isEmpty, "oldest spelling is pruned at the storage bound")
            for i in 0...CandidateLearning.maximumChoices {
                bounded.record(spelling: "ci", commit: String(UnicodeScalar(0x4E00 + i)!), at: day.addingTimeInterval(Double(i)))
            }
            check(bounded.choices(for: "ci").count == CandidateLearning.maximumChoices, "per-spelling alternatives stay bounded")

            // Same native selection path as mouse, digits and Space/Enter.
            type("youxiang")
            let pool = engine.candidatePool(20)
            check(pool.first != "又想", "isolated dictionary begins without this preference")
            let index = pool.firstIndex(of: "又想")!
            let spelling = engine.rawInput()
            engine.selectGlobal(UInt(index))
            let commit = engine.takeCommit()
            check(commit == "又想" && engine.rawInput().isEmpty, "selection commits the intended candidate")
            store.record(spelling: spelling, commit: commit)
            type("youxiang")
            check(engine.candidatePool(20).first == "又想", "Rime immediately learns the same choice")
            engine.clear()
            type("youxiang")
            engine.selectGlobal(UInt(engine.candidatePool(20).firstIndex(of: "有")!))
            store.record(spelling: engine.rawInput(), commit: engine.takeCommit())
            engine.clear()
            check(store.learning.choices(for: "youxiang").count == 1, "cancelled partial selection adds no personalized history")
            type("hello")
            store.record(spelling: "hello", commit: engine.takeRawInput())
            check(store.learning.choices(for: "hello").isEmpty, "Shift raw-input conversion is never learned as Chinese")
            store.flush(wait: true)
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            check(permissions?.intValue == 0o600, "personal history is owner-only")
        } else {
            check(store.learning.choices(for: "youxiang")["又想"]?.count == 1, "choice survives a process restart")
            type("youxiang")
            let details = engine.candidateDetails(20)
            let pool = details.compactMap { $0["text"] as? String }
            let ends = details.compactMap { $0["coverageEnd"] as? Int }
            check(pool.first == "又想", "Rime learning also survives process restart")
            let context = JevContext(precedingText: "", pinyin: "youxiang", preedit: "you xiang", candidates: pool, coverageEnds: ends)
            let cloud = try JevRanking(answers: Dictionary(uniqueKeysWithValues: pool.indices.map {
                ("c\($0)", answer(pool[$0] == "邮箱" ? 4 : 0))
            }), candidateCount: pool.count, coverageEnds: ends)
            check(pool[cloud.indices[0]] == "邮箱", "cloud fixture would override learned native preference")
            let personalized = cloud.applyingLearning(store.learning, context: context)
            check(pool[personalized.indices[0]] == "又想", "persisted preference wins after the cloud response")
            engine.selectGlobal(UInt(personalized.indices[0]))
            check(engine.takeCommit() == "又想", "personalized displayed row commits through the correct Rime index")
        }
        engine.clear()
        LIRime.shutdown()
        print("PASS: candidate learning \(args[3]), native selection, cloud personalization and persistence")
    }
}
