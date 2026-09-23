import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("FAIL: \(message)") }
}

final class JevMockProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var failure: URLError?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct JevTests {
    static func main() async throws {
        let legacy = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        check(!legacy.jevEnabled, "existing installations remain offline by default")
        var settings = Settings(); settings.jevEnabled = true
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        check(restored.jevEnabled, "Jev preference round trips")
        let context = JevContext(precedingText: "汽车", pinyin: "youxiang", preedit: "you xiang",
                                 candidates: ["邮箱", "油箱", "又想"])
        let request = try JevClient.request(context: context, apiKey: "test-key")
        check(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone", "official API endpoint")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "bearer auth")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        check(body["model"] as? String == "jev-latest", "Jev model")
        let state = body["state"] as! [String: Any]
        check(state["precedingText"] as? String == "汽车", "exact context is supplied")
        check(state["candidates"] as? [String] == context.candidates, "candidate coverage")
        check(!String(data: request.httpBody!, encoding: .utf8)!.contains("test-key"), "key never becomes model state")
        let questions = body["questions"] as! [String: [String: Any]]
        check(questions.count == context.candidates.count, "every candidate gets one question in a single request")
        let criteria = questions["c0"]!["criteria"] as! [String]
        check(criteria.count == 5, "shared five-level semantic rubric")
        for index in context.candidates.indices {
            let question = questions["c\(index)"]!
            check(question["type"] as? String == "score", "use actual Score primitive for each candidate")
            check(question["criteria"] as? [String] == criteria, "all scores use identical criteria")
            check((question["instructions"] as! String).contains("`candidates[\(index)]`"), "instructions identify candidate; question ID is not model context")
        }
        let larger = JevContext(precedingText: "测试", pinyin: "shi", preedit: "shi", candidates: (0..<20).map { "候选\($0)" })
        let largerRequest = try JevClient.request(context: larger, apiKey: "test-key")
        let largerBody = try JSONSerialization.jsonObject(with: largerRequest.httpBody!) as! [String: Any]
        check((largerBody["questions"] as! [String: Any]).count == 20, "all 20 candidates scored, not just first-page items")

        func answer(_ value: Double) -> JevScore {
            let low = Int(value), high = min(4, low + 1), fraction = value - Double(low)
            var probabilities = Dictionary(uniqueKeysWithValues: (0...4).map { (String($0), 0.0) })
            probabilities[String(low)]! += 1 - fraction
            probabilities[String(high)]! += fraction
            return JevScore(type: "score", score: value, probabilities: probabilities, confidence: 0.7)
        }
        func ranking(_ values: [Double]) throws -> JevRanking {
            try JevRanking(answers: Dictionary(uniqueKeysWithValues: values.enumerated().map { ("c\($0.offset)", answer($0.element)) }), candidateCount: values.count)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JevMockProtocol.self]
        let client = JevClient(configuration: config)
        // Transport fixtures only; these numbers do not claim live model accuracy.
        for (prefix, values, expected) in [("汽车", [0.4, 3.9, 1.2], [1, 2, 0]),
                                           ("我现在", [1.0, 0.2, 3.8], [2, 0, 1]),
                                           ("请发到我的", [3.7, 0.8, 1.5], [0, 2, 1]),
                                           ("", [2.0, 2.0, 2.0], [0, 1, 2])] {
            let answers: [String: Any] = Dictionary(uniqueKeysWithValues: values.enumerated().map {
                let value = answer($0.element)
                return ("c\($0.offset)", ["type": value.type, "score": value.score,
                    "confidence": value.confidence, "probabilities": value.probabilities] as [String: Any])
            })
            JevMockProtocol.body = try JSONSerialization.data(withJSONObject: ["answers": answers])
            let input = JevContext(precedingText: prefix, pinyin: context.pinyin, preedit: context.preedit, candidates: context.candidates)
            let result = try await client.rank(context: input, apiKey: "test-key")
            check(result.indices == expected, "sort every candidate, including second and third places for \(prefix)")
            check(abs(result.scores[1] - values[1] * 25) < 0.0001, "display scores normalized to 100, not confidence")
            let order = JevCandidateOrder(ranking: result, pageSize: 3)
            for row in 0..<3 { check(order.engineIndex(for: row) == expected[row], "numeric/mouse/space row mapping") }
        }
        let groupedAnswers = ["c0": answer(1), "c1": answer(4), "c2": answer(4), "c3": answer(3), "c4": answer(3)]
        let grouped = try JevRanking(answers: groupedAnswers, candidateCount: 5, coverageEnds: [8, 5, 3, 8, 8])
        check(grouped.indices == [3, 4, 0, 1, 2], "low-scoring full words outrank every partial word; scores and stable ties apply only within coverage group")
        var groupedOrder = JevCandidateOrder(ranking: grouped, pageSize: 2)
        check(groupedOrder.indices == [3, 4], "first page contains highest-scoring full words")
        check(groupedOrder.turnPage(1) && groupedOrder.indices == [0, 1], "group boundary persists across pages without losing original indices")
        check(groupedOrder.partialRows(inputLength: 8) == [1], "only the partial candidate carries the partial-conversion badge")
        check(groupedOrder.engineIndex(for: 1) == 1, "partial candidate still commits through its own original Rime index")
        do { _ = try JevRanking(answers: groupedAnswers, candidateCount: 5, coverageEnds: [8]); fatalError("incomplete coverage accepted") }
        catch JevError.invalidResponse {}
        let coveredContext = JevContext(precedingText: "汽车", pinyin: "youxiang", preedit: "you xiang",
            candidates: ["油箱", "游戏", "有"], coverageEnds: [8, 5, 3])
        let coveredRequest = try JevClient.request(context: coveredContext, apiKey: "test-key")
        let coveredBody = try JSONSerialization.jsonObject(with: coveredRequest.httpBody!) as! [String: Any]
        check((coveredBody["state"] as! [String: Any])["remainingInputs"] as? [String] == ["", "ang", "xiang"], "model sees exact unconverted suffix instead of assuming all options cover whole pinyin")
        let tied = try ranking([2, 3, 3, 0])
        check(tied.indices == [1, 2, 0, 3], "ties preserve original Rime order")
        let equal = try ranking([2, 2, 2])
        check(equal.indices == [0, 1, 2], "undistinguished candidates keep local order")
        let rounded = JevScore(type: "score", score: 0.79,
            probabilities: ["0": 0.59, "1": 0.18, "2": 0.11, "3": 0.06, "4": 0.06], confidence: 0.34)
        check(rounded.isValid, "accept observed API rounding difference instead of rejecting the entire batch")
        let roundedRanking = try JevRanking(answers: ["c0": rounded], candidateCount: 1)
        check(abs(roundedRanking.scores[0] - 19.75) < 0.0001, "use returned score rather than reconstructing from rounded probabilities")
        let malformed = [
            JevScore(type: "choice", score: 2, probabilities: answer(2).probabilities, confidence: 1),
            JevScore(type: "score", score: 5, probabilities: answer(2).probabilities, confidence: 1),
            JevScore(type: "score", score: 1, probabilities: answer(3).probabilities, confidence: 1),
            JevScore(type: "score", score: 1, probabilities: ["0": 1], confidence: 1),
            JevScore(type: "score", score: .nan, probabilities: answer(2).probabilities, confidence: 1)
        ]
        check(malformed.allSatisfy { !$0.isValid }, "reject wrong primitive, out-of-range, inconsistent and non-finite scores")
        for answers in [["c0": answer(3)], ["c0": answer(3), "foreign": answer(2)], ["c0": answer(3), "c1": malformed[0]]] {
            do { _ = try JevRanking(answers: answers, candidateCount: 2); fatalError("partial/invalid rankings accepted") }
            catch JevError.invalidResponse {}
        }
        let values = (0..<20).map { Double($0) / 5 }
        var order = JevCandidateOrder(ranking: try ranking(values), pageSize: 5)
        check(order.indices == [19, 18, 17, 16, 15], "later native pages can fill the first ranked page")
        order.move(1)
        check(order.engineIndex(for: order.selected) == 18, "arrow navigation retains original candidate index")
        check(order.turnPage(1) && order.indices == [14, 13, 12, 11, 10] && order.selected == 0, "next page remains globally ranked")
        var all = [19, 18, 17, 16, 15] + order.indices
        while order.turnPage(1) { all += order.indices }
        check(all == Array((0..<20).reversed()), "all scores appear in descending order without duplicates or omissions")
        check(!order.turnPage(1) && order.page == 3, "past ranked pool returns control to native page four")
        check(order.turnPage(-1) && order.indices == [9, 8, 7, 6, 5], "backward paging retains ranking")
        check(order.engineIndex(for: 5) == nil, "out-of-range row rejected")
        var partial = JevCandidateOrder(ranking: try ranking([1, 2, 3, 4, 0, 2.5]), pageSize: 5)
        check(partial.turnPage(1) && partial.indices == [4], "short final page maps correctly")
        partial.move(50); check(partial.selected == 0, "navigation clamps on a partial page")
        for status in [401, 429, 529] {
            JevMockProtocol.status = status
            do { _ = try await client.rank(context: context, apiKey: "test-key"); fatalError("HTTP failure accepted") }
            catch JevError.service(let code) { check(code == status, "service errors reach local fallback") }
        }
        JevMockProtocol.status = 200; JevMockProtocol.body = Data("{}".utf8)
        do { _ = try await client.rank(context: context, apiKey: "test-key"); fatalError("malformed response accepted") }
        catch {}
        JevMockProtocol.failure = URLError(.timedOut)
        do { _ = try await client.rank(context: context, apiKey: "test-key"); fatalError("timeout accepted") }
        catch { check((error as? URLError)?.code == .timedOut, "timeout reaches local fallback") }
        print("PASS: Jev batched Score contract, complete descending rankings, stable ties, paginated index mapping, malformed/partial result fallback, service failures, settings migration (no live API calls)")
    }
}
