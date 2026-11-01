import Foundation

enum TypingScheme: String, Codable, CaseIterable, Identifiable {
    case fullPinyin = "luna_pinyin_simp"
    case xiaoheDoublePinyin = "double_pinyin_flypy"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullPinyin: return "雾凇全拼"
        case .xiaoheDoublePinyin: return "小鹤双拼"
        }
    }
    // Jev's prompt and supplementary learning keys currently assume full pinyin.
    // Keep double-pinyin codes local rather than mislabel them as full syllables.
    var supportsJev: Bool { self == .fullPinyin }
}
