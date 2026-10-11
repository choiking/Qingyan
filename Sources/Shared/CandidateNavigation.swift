import Foundation

// Display positions are independent of Rime's five-item native pages.
struct CandidateNavigation {
    enum Action { case left, right, up, down, previousPage, nextPage, toggle }
    static let columns = 6
    static let expandedSize = 36
    private(set) var selected = 0
    private(set) var expanded = false
    var capacity: Int { expanded ? Self.expandedSize : Self.columns }
    var start: Int { selected / capacity * capacity }
    var numberedRowStart: Int { selected / Self.columns * Self.columns }
    func visibleRange(count: Int) -> Range<Int> { min(start, count)..<min(start + capacity, count) }
    func numberPosition(_ number: Int, count: Int) -> Int? {
        let position = numberedRowStart + number - 1
        return (1...Self.columns).contains(number) && position < count ? position : nil
    }
    mutating func navigate(_ action: Action, count: Int) {
        guard count > 0 else { return }
        switch action {
        case .left: selected = max(0, selected - 1)
        case .right: selected = min(count - 1, selected + 1)
        case .down:
            if !expanded { expanded = true }
            else { selected = min(count - 1, selected + Self.columns) }
        case .up:
            if expanded && selected < Self.columns { expanded = false }
            else { selected = max(0, selected - Self.columns) }
        case .previousPage: selected = max(0, start - capacity)
        case .nextPage:
            if start + capacity < count { selected = start + capacity }
        case .toggle: expanded.toggle()
        }
    }
}
