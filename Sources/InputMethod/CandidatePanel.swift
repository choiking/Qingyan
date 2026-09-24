import AppKit

final class CandidatePanel: NSPanel {
    private let stack = NSStackView()
    var onSelect: ((Int) -> Void)?
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
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
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
    @objc private func selectCandidate(_ sender: NSButton) { onSelect?(sender.tag) }
}
