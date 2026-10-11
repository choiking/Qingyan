import Foundation

@main struct CandidateNavigationTests {
    static func main() {
        func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        var nav = CandidateNavigation()
        check(nav.visibleRange(count: 80) == 0..<6, "initial view has six candidates")
        nav.navigate(.down, count: 80)
        check(nav.expanded && nav.selected == 0 && nav.visibleRange(count: 80) == 0..<36,
              "first Down expands without skipping the first candidate")
        nav.navigate(.right, count: 80)
        nav.navigate(.down, count: 80)
        check(nav.selected == 7 && nav.numberPosition(1, count: 80) == 6 && nav.numberPosition(6, count: 80) == 11,
              "vertical movement preserves column and numbers address highlighted row")
        for _ in 0..<5 { nav.navigate(.down, count: 80) }
        check(nav.selected == 37 && nav.start == 36, "Down crosses to the next grid page")
        nav.navigate(.up, count: 80)
        check(nav.expanded && nav.selected == 31 && nav.start == 0, "Up crosses to preceding grid page without collapsing")
        nav.navigate(.down, count: 80)
        nav.navigate(.left, count: 80)
        nav.navigate(.left, count: 80)
        check(nav.selected == 35 && nav.start == 0, "Left returns to preceding page last item")
        nav.navigate(.up, count: 80)
        check(nav.selected == 29, "Up moves to previous row")
        nav.navigate(.nextPage, count: 80)
        check(nav.selected == 36, "next page starts at first item")
        nav.navigate(.nextPage, count: 80)
        nav.navigate(.down, count: 80)
        check(nav.selected == 78 && nav.numberPosition(3, count: 80) == nil,
              "numbers outside final short row do not select another word")
        nav.navigate(.down, count: 80)
        check(nav.selected == 79, "last partial row clamps at final candidate")
        nav.navigate(.nextPage, count: 80)
        check(nav.selected == 79, "paging beyond the end keeps selection")
        nav.navigate(.toggle, count: 80)
        check(!nav.expanded && nav.visibleRange(count: 80) == 78..<80, "collapse retains selected word")
        nav = CandidateNavigation()
        nav.navigate(.down, count: 2)
        nav.navigate(.up, count: 2)
        check(!nav.expanded && nav.selected == 0, "Up on first expanded row collapses")
        nav.navigate(.left, count: 2)
        nav.navigate(.previousPage, count: 2)
        check(nav.selected == 0, "start boundary never wraps")
        print("PASS: six-column grid, expansion, row/column navigation, paging, numeric selection, short final row and collapse")
    }
}
