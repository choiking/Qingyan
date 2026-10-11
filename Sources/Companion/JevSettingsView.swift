import SwiftUI

struct JevSettingsView: View {
    @ObservedObject var service: VoiceService
    @State private var apiKey = ""
    @State private var hasKey = !JevCredential.load().isEmpty
    @State private var status = ""
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Jev 上下文选词", systemImage: "sparkles").font(.title2.bold())
            Text("完整匹配优先。相同拼音下，已确认的词按使用次数、最近使用时间优先排列，其余候选再按 Jev 分数排序。")
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("汽车 youxiang → 油箱\n我现在 youxiang → 又想\n请发到我的 youxiang → 邮箱")
                        .lineSpacing(8)
                    Text("游戏只匹配 youxi，有只匹配 you，会排在完整匹配之后并标注「部分」。Jev 分数表示语境适配程度；用词习惯会影响最终顺序，因此分数不一定递减。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Toggle("启用 Jev 云端选词", isOn: $service.settings.jevEnabled)
                .onChange(of: service.settings.jevEnabled) { service.saveSettings() }
            Text("选词后自动在本机记住拼音和词条，下次输入相同拼音即可参与排序，重启后保留。无需开启「用词统计」，选词次数不会发送给 Jev。")
                .font(.callout).foregroundStyle(.secondary)
            Text("启用并配置 Key 后，会将光标前最多 128 个 UTF-16 字符、当前拼音、预编辑文字及最多 20 个候选与覆盖信息发送到 TypeSafe。翻页保留分组顺序；超出范围使用本地顺序。覆盖无法确认、缺分或请求失败时保留本地候选。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                SecureField(hasKey ? "填写新的 TypeSafe API Key 以替换" : "TypeSafe API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存 Key") {
                        do {
                            try JevCredential.save(apiKey)
                            apiKey = ""; hasKey = true
                            status = "Key 已保存。开启上方开关后，切回输入框即可使用。"
                        } catch { status = "保存失败：\(error.localizedDescription)" }
                    }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                    Button("移除 Key") {
                        do {
                            try JevCredential.save("")
                            hasKey = false; apiKey = ""
                            service.settings.jevEnabled = false; service.saveSettings()
                            status = "Key 已移除，已恢复本地选词。"
                        } catch { status = "移除失败：\(error.localizedDescription)" }
                    }.disabled(!hasKey || testing)
                    Spacer()
                    Button(testing ? "测试中…" : "测试示例") { testExamples() }
                        .disabled(!hasKey || testing)
                }
                Text("Key 保存在本机当前用户专用文件（权限 0600）。测试只发送三个示例，会使用 API 额度。分数表示语境适配程度，不是正确率。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !status.isEmpty {
                ScrollView { Text(status).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 130)
            }
            Spacer()
        }.padding(28)
        .onDisappear { testTask?.cancel(); testing = false }
    }

    private func testExamples() {
        testing = true; status = "正在连接 TypeSafe…"
        let key = JevCredential.load()
        testTask = Task { @MainActor in
            defer { testing = false }
            var lines: [String] = []
            do {
                for prefix in ["汽车", "我现在", "请发到我的"] {
                    let context = JevContext(precedingText: prefix, pinyin: "youxiang", preedit: "you xiang",
                                             candidates: ["邮箱", "油箱", "又想"])
                    let ranking = try await JevClient.shared.rank(context: context, apiKey: key)
                    try Task.checkCancellation()
                    let words = ranking.indices.map { "\(context.candidates[$0]) \(String(format: "%.1f", ranking.scores[$0]))" }
                    lines.append("\(prefix) youxiang\n" + words.joined(separator: "  >  "))
                }
                status = lines.joined(separator: "\n")
            } catch is CancellationError {} catch { status = "测试失败：\(error.localizedDescription)" }
        }
    }
}
