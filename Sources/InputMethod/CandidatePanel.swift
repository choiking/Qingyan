import AppKit

private final class CandidateBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        border.lineWidth = 0.5
        border.stroke()
    }
}

struct CandidateGridItem {
    let text: String
    var number: Int? = nil
    var score: Double? = nil
    var partial = false
    var scoreLabel: String? { score.map { "Jev \(String(format: "%.1f", $0))" } }
    static func scoreFont(for size: CGFloat) -> NSFont {
        .monospacedDigitSystemFont(ofSize: max(11, min(15, size * 0.62)), weight: .regular)
    }
}

private final class CandidateCell: NSButton {
    let item: CandidateGridItem
    let chosen: Bool
    init(item: CandidateGridItem, chosen: Bool, fontSize: CGFloat) {
        self.item = item
        self.chosen = chosen
        super.init(frame: .zero)
        isBordered = false
        title = item.text
        font = .systemFont(ofSize: fontSize)
        toolTip = item.text + (item.partial ? " · 部分匹配" : "") +
            (item.score.map { " · Jev \(String(format: "%.1f", $0))" } ?? "")
        setAccessibilityLabel((item.number.map { "\($0) " } ?? "") + item.text +
                              (item.scoreLabel.map { "，\($0)" } ?? ""))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let size = font?.pointSize ?? 18
        let numberWidth: CGFloat = 18
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font!, .foregroundColor: chosen ? NSColor.white : NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let textWidth = (item.text as NSString).size(withAttributes: attributes).width
        let scoreAttributes: [NSAttributedString.Key: Any] = [
            .font: CandidateGridItem.scoreFont(for: size),
            .foregroundColor: chosen ? NSColor.white.withAlphaComponent(0.9) : NSColor.secondaryLabelColor
        ]
        let scoreSize = item.scoreLabel.map { ($0 as NSString).size(withAttributes: scoreAttributes) } ?? .zero
        let scoreSpace = item.scoreLabel == nil ? 0 : ceil(scoreSize.width) + 8
        let availableTextWidth = max(0, bounds.width - numberWidth - 16 - scoreSpace)
        let displayedTextWidth = min(textWidth, availableTextWidth)
        if chosen {
            NSColor(srgbRed: 0, green: 0.69, blue: 0.47, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: min(bounds.width - 4, displayedTextWidth + scoreSpace + numberWidth + 18),
                                            height: bounds.height - 6), xRadius: 8, yRadius: 8).fill()
        }
        let height = ceil(size * 1.5)
        let y = (bounds.height - height) / 2
        if let number = item.number {
            (String(number) as NSString).draw(in: NSRect(x: 9, y: y + 2, width: numberWidth, height: height),
                withAttributes: [.font: NSFont.systemFont(ofSize: size * 0.78, weight: .medium),
                                 .foregroundColor: chosen ? NSColor.white : NSColor.secondaryLabelColor])
        }
        (item.text as NSString).draw(in: NSRect(x: 9 + numberWidth, y: y, width: availableTextWidth, height: height),
                                    withAttributes: attributes)
        if let label = item.scoreLabel {
            (label as NSString).draw(in: NSRect(x: 9 + numberWidth + displayedTextWidth + 8,
                                              y: (bounds.height - scoreSize.height) / 2,
                                              width: ceil(scoreSize.width), height: ceil(scoreSize.height)),
                                     withAttributes: scoreAttributes)
        }
    }
}

final class CandidatePanel: NSPanel {
    private let stack = NSStackView()
    var onSelect: ((Int) -> Void)?
    var onNavigate: ((CandidateNavigation.Action) -> Void)?
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .init(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = CandidateBackground()
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        contentView = background
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func show(title: String, candidates: [String] = [], selected: Int = -1,
              scores: [Double]? = nil,
              partialRows: Set<Int> = [], numbered: Bool = true,
              detail: String, anchor: NSRect) {
        onNavigate = nil
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .systemFont(ofSize: Settings.load().fontSize, weight: .medium)
        heading.maximumNumberOfLines = 5
        heading.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(heading)
        for (index, text) in candidates.enumerated() {
            let badge = scores.flatMap { $0.indices.contains(index) ? "  ✦ Jev \(String(format: "%.1f", $0[index]))" : nil } ?? ""
            let coverage = partialRows.contains(index) ? "（部分）" : ""
            let button = NSButton(title: "\(numbered ? "\(index + 1)  " : "")\(text)\(coverage)\(badge)", target: self, action: #selector(selectCandidate(_:)))
            button.tag = index
            // A long 猜你想说 line is cut at the panel's maximum width instead of widening it.
            button.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: Settings.load().fontSize)
            button.contentTintColor = index == selected ? .systemTeal : .labelColor
            stack.addArrangedSubview(button)
        }
        let footnote = NSTextField(wrappingLabelWithString: detail)
        footnote.preferredMaxLayoutWidth = 420
        footnote.maximumNumberOfLines = 3
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(footnote)
        let fitted = stack.fittingSize
        let size = NSSize(width: min(460, max(260, fitted.width)), height: max(70, fitted.height))
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(anchor.minX, bounds.minX + 8), bounds.maxX - size.width - 8)
        var y = anchor.minY - size.height - 6
        if y < bounds.minY { y = min(anchor.maxY + 6, bounds.maxY - size.height - 8) }
        setFrame(NSRect(origin: NSPoint(x: x, y: max(bounds.minY + 8, y)), size: size), display: true)
        orderFrontRegardless()
    }
    func showGrid(items: [CandidateGridItem], selected: Int, expanded: Bool,
                  canPrevious: Bool, canNext: Bool, status: String, page: Int, anchor: NSRect) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 0, right: 4)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fontSize = CGFloat(Settings.load().fontSize)
        let longest = items.map { item in
            let textWidth = (item.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
            let scoreWidth = item.scoreLabel.map { ($0 as NSString).size(withAttributes: [.font: CandidateGridItem.scoreFont(for: fontSize)]).width + 8 } ?? 0
            return textWidth + scoreWidth
        }.max() ?? 36
        let maximumCellWidth: CGFloat = items.contains { $0.score != nil } ? 210 : 156
        let cellWidth = min(max(86, min(maximumCellWidth, longest + 42)), (bounds.width - 24) / 6)
        let width = cellWidth * 6
        let rowHeight = max(38, ceil(fontSize * 1.5 + 12))
        let rows = max(1, (items.count + 5) / 6)
        for row in 0..<rows {
            if row > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                divider.widthAnchor.constraint(equalToConstant: width).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(divider)
            }
            let line = NSStackView()
            line.orientation = .horizontal
            line.spacing = 0
            for column in 0..<6 {
                let index = row * 6 + column
                let cell: NSView
                if items.indices.contains(index) {
                    let button = CandidateCell(item: items[index], chosen: index == selected, fontSize: fontSize)
                    button.tag = index
                    button.target = self
                    button.action = #selector(selectCandidate(_:))
                    cell = button
                } else { cell = NSView() }
                cell.widthAnchor.constraint(equalToConstant: cellWidth).isActive = true
                cell.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
                line.addArrangedSubview(cell)
            }
            stack.addArrangedSubview(line)
        }
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 2, left: 9, bottom: 3, right: 6)
        let hint = NSTextField(labelWithString: status.isEmpty ? (expanded ? "↑↓ 换行 · ←→ 选词" : "↓ 展开候选") : status)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(hint)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        let pageLabel = NSTextField(labelWithString: "\(page)")
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        pageLabel.textColor = .tertiaryLabelColor
        footer.addArrangedSubview(pageLabel)
        for (tag, symbol, help, enabled) in [(0, "chevron.left", "上一页（-）", canPrevious),
                                             (1, "chevron.right", "下一页（=）", canNext),
                                             (2, expanded ? "chevron.up" : "chevron.down", expanded ? "收起候选" : "展开候选（↓）", true)] {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: self,
                                  action: #selector(navigate(_:)))
            button.tag = tag
            button.isBordered = false
            button.isEnabled = enabled
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = help
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            footer.addArrangedSubview(button)
        }
        footer.widthAnchor.constraint(equalToConstant: width).isActive = true
        footer.heightAnchor.constraint(equalToConstant: 25).isActive = true
        stack.addArrangedSubview(footer)
        let size = NSSize(width: width + 8, height: 3 + CGFloat(rows) * rowHeight + CGFloat(rows - 1) + 25)
        let x = min(max(anchor.minX, bounds.minX + 8), bounds.maxX - size.width - 8)
        var y = anchor.minY - size.height - 6
        if y < bounds.minY { y = min(anchor.maxY + 6, bounds.maxY - size.height - 8) }
        setFrame(NSRect(origin: NSPoint(x: x, y: max(bounds.minY + 8, y)), size: size), display: true)
        contentView?.layoutSubtreeIfNeeded()
        orderFrontRegardless()
    }
    @objc private func navigate(_ sender: NSButton) {
        onNavigate?(sender.tag == 0 ? .previousPage : sender.tag == 1 ? .nextPage : .toggle)
    }
    @objc private func selectCandidate(_ sender: NSButton) { onSelect?(sender.tag) }
}
