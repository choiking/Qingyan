import AppKit

struct VoiceShortcut: Codable, Equatable {
    enum Trigger: String, Codable { case keyDown, modifierPress, modifierTap, modifierHold }
    var keyCode: UInt16
    var modifiers: UInt
    var trigger: Trigger

    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    static let defaultShortcut = VoiceShortcut(keyCode: 49,
        modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
    static let functionKeys: Set<UInt16> = [64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122]
    static let modifierNames: [UInt16: String] = [54: "右 Command", 55: "左 Command", 56: "左 Shift",
        58: "左 Option", 59: "左 Control", 60: "右 Shift", 61: "右 Option", 62: "右 Control", 63: "Fn"]
    // Device-specific masks from the macOS SDK's IOKit/hidsystem/IOLLEvent.h.
    static let physicalMasks: [UInt16: UInt] = [54: 0x10, 55: 0x08, 56: 0x02, 58: 0x20,
        59: 0x01, 60: 0x04, 61: 0x40, 62: 0x2000]
    static let oppositeKeys: [UInt16: UInt16] = [54: 55, 55: 54, 56: 60, 60: 56, 58: 61, 61: 58, 59: 62, 62: 59]
    static func modifierFlag(for key: UInt16) -> NSEvent.ModifierFlags {
        switch key {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return []
        }
    }
    static func isModifierDown(_ key: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if let mask = physicalMasks[key] {
            if flags.rawValue & mask != 0 { return true }
            if let opposite = oppositeKeys[key], let other = physicalMasks[opposite], flags.rawValue & other != 0 { return false }
        }
        return !modifierFlag(for: key).isEmpty && flags.contains(modifierFlag(for: key))
    }
    var isModifier: Bool { trigger != .keyDown }

    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete",
        64: "F17", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
        76: "Keypad Enter", 78: "Keypad −", 79: "F18", 80: "F19", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 90: "F20", 91: "Keypad 8", 92: "Keypad 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
    init(keyCode: UInt16, modifiers: UInt, trigger: Trigger = .keyDown) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask.rawValue
        self.trigger = trigger
    }
    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, trigger }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        modifiers = try c.decode(UInt.self, forKey: .modifiers)
        trigger = try c.decodeIfPresent(Trigger.self, forKey: .trigger) ?? .keyDown
    }
    var validationError: String? {
        if isModifier {
            return modifiers == 0 && Self.modifierNames[keyCode] != nil ? nil : "请选择一个修饰键，例如右 Option 或 Fn。"
        }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        guard modifiers == flags.intersection(Self.modifierMask).rawValue else { return "不支持这组修饰键。" }
        guard Self.functionKeys.contains(keyCode) || !flags.intersection([.control, .option, .command]).isEmpty else {
            return "普通打字键需搭配修饰键；可单按 F1–F20，或单独使用 Fn / Option 等键。"
        }
        guard Self.keyNames[keyCode] != nil else { return "这个按键暂不支持，请换一个组合键。" }
        if keyCode == 49 && (flags == .command || flags == .control || flags == [.control, .shift]) {
            return "这组按键常用于系统搜索或切换输入法，请换一组。"
        }
        return nil
    }
    var displayName: String {
        if isModifier { return Self.modifierNames[keyCode] ?? "?" }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") +
            (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") +
            (Self.keyNames[keyCode] ?? "?")
    }
    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        !isModifier && self.keyCode == keyCode && modifiers == flags.intersection(Self.modifierMask).rawValue
    }
}

// A press starts once; releasing the key OR any required modifier ends it once.
// Legacy tap/hold bindings retain their physical key, now with push-to-talk behavior.
struct VoicePressTracker {
    enum Action { case none, start, stop, cancel }
    private(set) var held: VoiceShortcut?
    mutating func reset() { held = nil }
    mutating func update(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags,
                         isRepeat: Bool = false, binding: VoiceShortcut) -> Action {
        if let current = held {
            if type == .keyUp && keyCode == current.keyCode && !current.isModifier {
                reset(); return .stop
            }
            if type == .flagsChanged {
                if current.isModifier {
                    if keyCode != current.keyCode { reset(); return .cancel }
                    if !VoiceShortcut.isModifierDown(keyCode, flags: flags) { reset(); return .stop }
                } else {
                    let changedFlag = VoiceShortcut.modifierFlag(for: keyCode)
                    let required = NSEvent.ModifierFlags(rawValue: current.modifiers)
                    if !changedFlag.isEmpty, required.contains(changedFlag), !flags.contains(changedFlag) {
                        reset(); return .stop
                    }
                }
            }
            if type == .keyDown && (current.isModifier || keyCode != current.keyCode) {
                reset(); return .cancel
            }
            return .none
        }
        if type == .keyDown, !isRepeat, binding.matches(keyCode: keyCode, flags: flags) {
            held = binding; return .start
        }
        if type == .flagsChanged, binding.isModifier, keyCode == binding.keyCode,
           VoiceShortcut.isModifierDown(keyCode, flags: flags),
           flags.intersection([.control, .option, .shift, .command, .function]) == VoiceShortcut.modifierFlag(for: keyCode) {
            let opposite = VoiceShortcut.oppositeKeys[keyCode].flatMap { VoiceShortcut.physicalMasks[$0] } ?? 0
            if flags.rawValue & opposite == 0 { held = binding; return .start }
        }
        return .none
    }
}

