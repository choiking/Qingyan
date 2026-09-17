import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: VoiceShortcut
    let onSave: (VoiceShortcut) -> Bool
    let onStatus: (String?) -> Void

    func makeNSView(context: Context) -> ShortcutButton { ShortcutButton() }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.shortcut = shortcut
        button.onSave = onSave
        button.onStatus = onStatus
        button.isEnabled = context.environment.isEnabled
        if !button.isEnabled { button.stop() }
        button.refreshTitle()
    }
    static func dismantleNSView(_ button: ShortcutButton, coordinator: ()) { button.stop() }
}

final class ShortcutButton: NSButton {
    var shortcut = VoiceShortcut.defaultShortcut
    var onSave: ((VoiceShortcut) -> Bool)?
    var onStatus: ((String?) -> Void)?
    private var monitor: Any?
    private var focusObserver: NSObjectProtocol?
    private var recording = false
    private var pendingModifier: (key: UInt16, time: TimeInterval)?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self
        action = #selector(startRecording)
        setAccessibilityLabel("语音输入快捷键")
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }
    func refreshTitle() {
        title = recording ? "请按下按键…" : shortcut.displayName
        setAccessibilityValue(title)
    }
    @objc private func startRecording() {
        if recording { stop(); return }
        guard let window else { return }
        recording = true
        refreshTitle()
        onStatus?("按功能键或组合键；修饰键请单独按下再松开。Esc 取消。")
        // Local to this app, and only while its window is active. No global keyboard permissions.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self, weak window] event in
            guard let self, self.recording else { return event }
            guard NSApp.isActive, window?.isKeyWindow == true,
                  event.window === window || (event.type == .flagsChanged && event.window == nil) else {
                self.stop(); return event
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.stop() }
                return event
            }
            if event.type == .flagsChanged {
                let flags = event.modifierFlags
                if VoiceShortcut.isModifierDown(event.keyCode, flags: flags) {
                    let meaningful = flags.intersection([.control, .option, .shift, .command, .function])
                    let oppositeMask = VoiceShortcut.oppositeKeys[event.keyCode].flatMap { VoiceShortcut.physicalMasks[$0] } ?? 0
                    if self.pendingModifier == nil && meaningful == VoiceShortcut.modifierFlag(for: event.keyCode),
                       VoiceShortcut.modifierNames[event.keyCode] != nil, flags.rawValue & oppositeMask == 0 {
                        self.pendingModifier = (event.keyCode, event.timestamp)
                    } else { self.pendingModifier = nil }
                } else if let pending = self.pendingModifier, pending.key == event.keyCode {
                    self.pendingModifier = nil
                    if flags.intersection([.control, .option, .shift, .command, .function]).isEmpty {
                        self.save(VoiceShortcut(keyCode: pending.key, modifiers: 0,
                            trigger: .modifierPress))
                    }
                } else { self.pendingModifier = nil }
                return nil
            }
            self.pendingModifier = nil
            if event.keyCode == 53 { self.stop(); return nil }
            if event.isARepeat { return nil }
            let candidate = VoiceShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue)
            if let error = candidate.validationError { self.onStatus?(error); return nil }
            self.save(candidate)
            return nil
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in self?.stop() }
    }
    private func save(_ candidate: VoiceShortcut) {
        if let error = candidate.validationError { onStatus?(error); return }
        if onSave?(candidate) == true {
            shortcut = candidate
            stop()
            onStatus?("已保存：按住 \(candidate.displayName) 说话，文字实时显示，松开定稿。")
        } else { stop(); onStatus?("保存失败，请重试。") }
    }
    func stop() {
        guard recording else { return }
        recording = false
        pendingModifier = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        refreshTitle()
        onStatus?(nil)
    }
}
