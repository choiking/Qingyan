import AppKit

@main struct PanelRender {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        let panel = CandidatePanel()
        let jev = CommandLine.arguments.contains("--jev")
        if CommandLine.arguments.contains("--grid") {
            var words = ["小", "笑", "🤣", "晓", "肖", "校", "消", "销", "效", "孝", "萧", "潇", "筱", "霄", "啸", "骁", "削", "宵", "下哦", "枭", "嚣", "魈", "箫", "硝", "逍", "焇", "西奥", "西澳", "瞎哦", "希奥", "下噢", "西岙", "夏哦", "细呦", "西傲", "霞哦"]
            if CommandLine.arguments.contains("--long") { words = ["请帮我查一下明天的航班", "请帮我", "情绪价值", "中华人民共和国", "你好", "输入法", "长候选需要完整显示在悬停提示中"] }
            let expanded = !CommandLine.arguments.contains("--collapsed")
            let selected = CommandLine.arguments.contains("--second-row") ? 8 : 0
            let items = words.prefix(expanded ? 36 : 6).enumerated().map { index, word in
                CandidateGridItem(text: word, number: index / 6 == selected / 6 ? index % 6 + 1 : nil,
                                  score: index < 20 && !CommandLine.arguments.contains("--unscored") ? [100.0, 49.0, 37.2, 0.0][index % 4] : nil)
            }
            panel.showGrid(items: items, selected: selected, expanded: expanded,
                           canPrevious: false, canNext: true, status: "", page: 1,
                           anchor: NSRect(x: -10000, y: -10000, width: 1, height: 20))
        } else if CommandLine.arguments.contains("--guess") {
            panel.show(title: "✦ 猜你想说", candidates: ["好的，我周六三点有空", "可以，一起打羽毛球", "这周六我可能要加班，下次再约你一起去打球好不好呀"],
                       selected: 0, detail: "↑↓ 选择  Enter 输入  Esc 取消 · 来源：截图识别",
                       anchor: NSRect(x: -10000, y: -10000, width: 1, height: 20))
        } else {
        panel.show(title: jev ? "you xiang" : "ni hao", candidates: jev ? ["油箱", "邮箱", "又想", "游戏", "有"] : ["你好", "拟好", "你号", "腻好", "逆号"], selected: 0,
                   scores: jev ? [97.5, 62.0, 45.0, 60.0, 50.0] : nil,
                   partialRows: jev ? [3, 4] : [],
                   detail: "完整匹配优先 · 同组按 Jev 分数 · 数字选词  − / = 翻页",
                   anchor: NSRect(x: -10000, y: -10000, width: 1, height: 20))
        }
        panel.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let view = panel.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let result = NSImage(size: view.bounds.size)
            result.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            bitmap.draw(in: view.bounds)
            result.unlockFocus()
            let png = NSBitmapImageRep(data: result.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])); exit(0) }
            catch { fputs("\(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
