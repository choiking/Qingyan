import AppKit

@main struct PanelRender {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let panel = CandidatePanel()
        let jev = CommandLine.arguments.contains("--jev")
        if CommandLine.arguments.contains("--guess") {
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
