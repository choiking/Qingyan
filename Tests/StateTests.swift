import Foundation
import AppKit

@main struct StateTests {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        var shift = ShiftTapTracker()
        check(!shift.update(shift: true, otherModifier: false, time: 1), "down does not toggle")
        check(shift.update(shift: false, otherModifier: false, time: 1.1), "tap toggles")
        _ = shift.update(shift: true, otherModifier: false, time: 2)
        shift.keyDown()
        check(!shift.update(shift: false, otherModifier: false, time: 2.1), "Shift+letter never toggles")
        _ = shift.update(shift: true, otherModifier: true, time: 3)
        check(!shift.update(shift: false, otherModifier: false, time: 3.1), "modifier chord never toggles")
        _ = shift.update(shift: true, otherModifier: false, time: 4)
        check(!shift.update(shift: false, otherModifier: false, time: 5), "long hold never toggles")
        var guardState = VoiceCommitGuard()
        let first = UUID(), second = UUID()
        guardState.begin(first)
        let generation = guardState.generation
        check(guardState.accepts(first, generation: generation), "same focus is valid")
        guardState.invalidate()
        check(!guardState.accepts(first, generation: generation), "late result rejected after focus loss")
        guardState.begin(second)
        check(!guardState.accepts(first, generation: guardState.generation), "old request cannot enter new session")
        let reply = VoiceReply(phase: "ready", text: "你好 👋 Hello")
        let decoded = try JSONDecoder().decode(VoiceReply.self, from: JSONEncoder().encode(reply))
        check(reply == decoded, "IPC Unicode round trip")
        let legacyData = Data(#"{"language":"en","fontSize":23,"shiftToggle":false,"modelPath":"/tmp/custom.bin"}"#.utf8)
        var migrated = try JSONDecoder().decode(Settings.self, from: legacyData)
        check(migrated.language == "en" && migrated.fontSize == 23 && !migrated.shiftToggle && migrated.modelPath == "/tmp/custom.bin",
              "upgrade must preserve all existing preferences")
        check(migrated.voiceShortcut == .defaultShortcut, "legacy settings retain original shortcut")
        let custom = VoiceShortcut(keyCode: 9, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
        migrated.voiceShortcut = custom
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(migrated))
        check(restored.voiceShortcut == custom && restored.language == "en", "custom shortcut survives save/reload")
        check(custom.displayName == "⌃⇧V", "shortcut label follows saved configuration")
        check(custom.matches(keyCode: 9, flags: [.control, .shift]), "custom combination triggers")
        check(custom.matches(keyCode: 9, flags: [.control, .shift, .capsLock, .numericPad, .function]),
              "caps lock and hardware event flags do not break shortcut")
        check(!custom.matches(keyCode: 9, flags: [.control]), "missing modifier passes through")
        check(!custom.matches(keyCode: 9, flags: [.control, .shift, .command]), "extra modifier passes through")
        check(!custom.matches(keyCode: 49, flags: [.control, .option]), "old shortcut no longer triggers after change")
        check(VoiceShortcut(keyCode: 9, modifiers: 0).validationError != nil, "plain typing cannot be bound")
        check(VoiceShortcut(keyCode: 9, modifiers: NSEvent.ModifierFlags.shift.rawValue).validationError != nil, "shift-only letter cannot be bound")
        check(VoiceShortcut(keyCode: 53, modifiers: NSEvent.ModifierFlags.control.rawValue).validationError != nil, "Escape remains available to cancel")
        check(VoiceShortcut(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue).validationError != nil, "reject common Spotlight conflict")
        let damaged = Data(#"{"language":"zh","fontSize":22,"voiceShortcut":{"keyCode":9,"modifiers":0}}"#.utf8)
        let repaired = try JSONDecoder().decode(Settings.self, from: damaged)
        check(repaired.language == "zh" && repaired.fontSize == 22 && repaired.voiceShortcut == .defaultShortcut,
              "invalid shortcut falls back without discarding other preferences")
        let oldShortcut = try JSONDecoder().decode(VoiceShortcut.self, from: Data(#"{"keyCode":9,"modifiers":393216}"#.utf8))
        check(oldShortcut.trigger == .keyDown, "0.1.1 shortcuts migrate to normal key presses")
        let f5 = VoiceShortcut(keyCode: 96, modifiers: 0)
        check(f5.validationError == nil && f5.matches(keyCode: 96, flags: [.function]), "bare F5 can trigger")
        check(!f5.matches(keyCode: 96, flags: [.command, .function]), "modified F5 does not match bare F5")
        let tap = VoiceShortcut(keyCode: 61, modifiers: 0, trigger: .modifierTap)
        let hold = VoiceShortcut(keyCode: 63, modifiers: 0, trigger: .modifierHold)
        check(tap.validationError == nil && hold.validationError == nil, "modifier-only gestures validate")
        check(!tap.matches(keyCode: 61, flags: []), "modifier gestures never use keyDown matcher")
        check(try JSONDecoder().decode(VoiceShortcut.self, from: JSONEncoder().encode(hold)) == hold, "hold gesture persists")
        let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        let leftOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
        var press = VoicePressTracker()
        func event(_ type: NSEvent.EventType, _ key: UInt16, _ flags: NSEvent.ModifierFlags,
                   _ binding: VoiceShortcut, repeatKey: Bool = false) -> VoicePressTracker.Action {
            press.update(type: type, keyCode: key, flags: flags, isRepeat: repeatKey, binding: binding)
        }
        check(event(.keyDown, 96, .function, f5) == .start, "F5 starts on down")
        check(event(.keyDown, 96, .function, f5, repeatKey: true) == .none, "autorepeat cannot restart or stop")
        check(event(.keyUp, 96, .function, f5) == .stop, "release stops")
        check(event(.keyUp, 96, .function, f5) == .none, "duplicate release is harmless")
        check(event(.keyDown, 96, .function, f5, repeatKey: true) == .none, "repeat without press is ignored")
        check(event(.keyDown, 9, [.control, .shift], custom) == .start, "combo starts")
        check(event(.flagsChanged, 59, .shift, custom) == .stop, "releasing required modifier first stops")
        check(event(.flagsChanged, 58, leftOption, tap) == .none, "left Option cannot start right Option")
        check(event(.flagsChanged, 61, rightOption, tap) == .start, "legacy tap starts on down")
        check(event(.flagsChanged, 61, [], tap) == .stop, "legacy tap now stops on release")
        check(event(.flagsChanged, 63, .function, hold) == .start, "legacy hold starts immediately")
        check(event(.flagsChanged, 63, [], hold) == .stop, "Fn release stops without duration threshold")
        check(event(.flagsChanged, 61, rightOption.union(leftOption), tap) == .none, "both sides cannot start a single-side binding")
        _ = event(.flagsChanged, 61, rightOption, tap)
        check(event(.keyDown, 0, rightOption, tap) == .cancel, "modifier plus typing cancels dictation")
        _ = event(.flagsChanged, 61, rightOption, tap)
        check(event(.flagsChanged, 55, [.option, .command], tap) == .cancel, "another modifier cancels modifier-only recording")
        _ = event(.keyDown, 96, .function, f5)
        press.reset()
        check(event(.keyUp, 96, .function, f5) == .none, "focus reset prevents later release action")
        _ = event(.keyDown, 96, .function, f5)
        check(event(.keyUp, 96, .function, custom) == .stop, "active press retains original binding")
        _ = event(.keyDown, 9, [.control, .shift], custom)
        check(event(.flagsChanged, 57, [], custom) == .none,
              "unrelated flags event cannot invent release of a required modifier")
        check(event(.keyUp, 8, [], custom) == .none, "unrelated key-up cannot release bound key")
        check(press.held == custom, "hold survives unrelated events")
        press.reset()
        let request = VoiceRequest(id: UUID(), language: "zh", created: Date(), heldShortcut: f5)
        let startTime = Date(timeIntervalSince1970: 1000)
        let lease = VoiceHoldLease(id: request.id, renewedAt: startTime)
        check(request.captureAdmission(command: nil, lease: lease, now: startTime) == .allowed,
              "event-owned hold starts without a global keyboard-state query")
        check(request.captureAdmission(command: "stop", lease: lease, now: startTime) == .released,
              "release before helper launch prevents late capture even with fresh heartbeat")
        check(request.captureAdmission(command: "cancel", lease: lease, now: startTime) == .cancelled,
              "cancel has its own admission result")
        check(request.captureAdmission(command: nil, lease: nil, now: startTime) == .disconnected,
              "missing heartbeat is connection loss, not key release")
        check(request.captureAdmission(command: nil, lease: lease, now: startTime.addingTimeInterval(3)) == .disconnected,
              "dead input-method owner cannot keep recording")
        check(request.captureAdmission(command: nil, lease: VoiceHoldLease(id: UUID(), renewedAt: startTime), now: startTime) == .disconnected,
              "another session's heartbeat cannot authorize capture")
        check(!VoiceHoldLease(id: request.id, renewedAt: startTime.addingTimeInterval(10)).isFresh(at: startTime),
              "future heartbeat rejected")
        _ = event(.keyDown, 96, .function, f5)
        // Modifier keys do not repeat. A held gesture must remain valid during long silent holds.
        for second in 0..<30 {
            let now = startTime.addingTimeInterval(Double(second))
            check(press.held == f5, "no event does not mean key-up")
            let renewed = VoiceHoldLease(id: request.id, renewedAt: now)
            check(request.captureAdmission(command: nil, lease: renewed, now: now.addingTimeInterval(0.15)) == .allowed,
                  "ongoing hold remains recordable after helper startup and between key events")
        }
        check(event(.keyUp, 96, .function, f5) == .stop, "real key-up ends sustained recording")
        // Exercise serialization and file separation across processes, including the launch race.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let holdFile = folder.appendingPathComponent("hold.json")
        let commandFile = folder.appendingPathComponent("command.json")
        try LocalPaths.write(VoiceCommand(action: "stop"), to: commandFile)
        try LocalPaths.write(lease, to: holdFile)
        let fromDisk = LocalPaths.read(VoiceHoldLease.self, from: holdFile)
        let command = LocalPaths.read(VoiceCommand.self, from: commandFile)
        check(request.captureAdmission(command: command?.action, lease: fromDisk, now: startTime) == .released,
              "a heartbeat write never overwrites a stop sent while helper starts")
        let testRequest = VoiceRequest(id: UUID(), language: "en", created: Date())
        check(testRequest.captureAdmission(command: nil, lease: nil, now: startTime) == .allowed,
              "standalone microphone test needs no event-owner heartbeat")
        let legacyRequest = try JSONDecoder().decode(VoiceRequest.self, from: JSONEncoder().encode(testRequest))
        check(legacyRequest.heldShortcut == nil, "legacy requests still decode")
        print("PASS: settings migration, push-to-talk press/release/repeat, chord cancellation, event-owned sustained holds, heartbeat timeout, IPC stop precedence, delayed launch cancellation, focus/session guards")
    }
}
