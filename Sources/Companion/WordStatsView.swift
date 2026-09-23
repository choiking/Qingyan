import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WordStatsView: View {
    @ObservedObject var service: VoiceService
    @State private var stats = WordStats.load()
    @State private var loadedAt: Date?
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var confirmClear = false
    @State private var status = ""
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private static let shown = 500

    enum Filter: String, CaseIterable { case all = "全部", typed = "打字", voice = "语音" }
    private struct Row: Identifiable { let id: String; let count: Int; let entry: WordStats.Entry }

    var body: some View {
        let rows = self.rows()
        VStack(alignment: .leading, spacing: 16) {
            Label("用词统计", systemImage: "chart.bar.xaxis").font(.title2.bold())
            Toggle("记录我的用词", isOn: $service.settings.wordStatsEnabled)
                .onChange(of: service.settings.wordStatsEnabled) { service.saveSettings() }
            Text("打字和语音上屏后按词累计次数，只保存在这台 Mac。不保存句子、词序或应用名称；英文模式下直接键入的字母不计入。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                tile("累计词次", rows.all.reduce(0) { $0 + $1.count })
                tile("不同的词", rows.all.count)
                tile("今天", stats?.days[WordStats.day(Date())] ?? 0)
            }
            HStack {
                Picker("来源", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                TextField("搜索词语", text: $query).textFieldStyle(.roundedBorder)
            }
            List(rows.shown) { row in
                HStack {
                    Text(row.id).textSelection(.enabled)
                    Spacer()
                    if filter == .all && row.entry.typed > 0 && row.entry.voice > 0 {
                        Text("打字 \(row.entry.typed) · 语音 \(row.entry.voice)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(row.count)").monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                }
            }
            .overlay { if rows.shown.isEmpty { Text(stats == nil ? "还没有记录" : "没有匹配的词").foregroundStyle(.secondary) } }
            HStack {
                Text(footer(rows.all.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("导出 CSV…") { export() }.disabled(stats == nil)
                Button("清除统计…") { confirmClear = true }.disabled(stats == nil)
            }
        }
        .padding(20)
        .onAppear { reload() }
        .onReceive(timer) { _ in reload() }
        .alert("清除全部用词统计？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) { clear() }
            Button("取消", role: .cancel) {}
        } message: { Text("删除后无法恢复。") }
    }

    private func rows() -> (all: [Row], shown: [Row]) {
        let all = (stats?.words ?? [:]).compactMap { word, entry -> Row? in
            let count = filter == .typed ? entry.typed : filter == .voice ? entry.voice : entry.total
            return count > 0 ? Row(id: word, count: count, entry: entry) : nil
        }
        let term = query.trimmingCharacters(in: .whitespaces)
        let matched = term.isEmpty ? all : all.filter { $0.id.localizedCaseInsensitiveContains(term) }
        let sorted = matched.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
        return (all, Array(sorted.prefix(Self.shown)))
    }
    private func footer(_ total: Int) -> String {
        if !status.isEmpty { return status }
        guard let stats else { return "" }
        let since = stats.since.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_Hans")))
        return total > Self.shown ? "自 \(since) 起 · 显示前 \(Self.shown) 个" : "自 \(since) 起"
    }
    private func tile(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
    // The input method writes the file; reread only when it has changed.
    private func reload() {
        let modified = try? WordStats.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard modified == nil || modified != loadedAt else { return }
        stats = WordStats.load()
        loadedAt = modified
    }
    private func export() {
        guard let stats else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "轻言用词统计.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = stats.words.sorted { $0.value.total != $1.value.total ? $0.value.total > $1.value.total : $0.key < $1.key }
            .map { "\($0.key),\($0.value.total),\($0.value.typed),\($0.value.voice),\(WordStats.day($0.value.last))" }
        // The byte-order mark lets spreadsheet apps detect UTF-8 Chinese.
        let csv = "\u{FEFF}词,合计,打字,语音,最近使用\n" + lines.joined(separator: "\n") + "\n"
        do { try csv.write(to: url, atomically: true, encoding: .utf8); status = "已导出 \(lines.count) 个词。" }
        catch { status = "导出失败：\(error.localizedDescription)" }
    }
    private func clear() {
        do {
            try FileManager.default.removeItem(at: WordStats.url)
            stats = nil; loadedAt = nil; status = "已清除。"
        } catch { status = "清除失败：\(error.localizedDescription)" }
    }
}
