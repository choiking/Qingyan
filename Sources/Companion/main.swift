import AppKit
import SwiftUI
import AVFoundation

if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--transcribe" {
    do {
        let samples = try PCM.read(URL(fileURLWithPath: CommandLine.arguments[2]))
        let start = Date()
        let language = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "auto"
        let text = try SpeechEngine().transcribe(samples, model: CommandLine.arguments[3], language: language, cancellation: CancellationFlag(), vocabulary: CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : "")
        print(text)
        fputs(String(format: "Local transcription: %.2fs audio, %.2fs processing\n", Double(samples.count) / 16000, Date().timeIntervalSince(start)), stderr)
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var service: VoiceService!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try LocalPaths.prepare() } catch { NSApp.terminate(nil); return }
        LocalPaths.cleanStaleSessions()
        service = VoiceService()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 700),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "轻言输入法"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(service: service))
        window.center()
        if CommandLine.arguments.count == 3, ["--render-settings", "--render-correction"].contains(CommandLine.arguments[1]) {
            if CommandLine.arguments[1] == "--render-correction" {
                // Export SwiftUI directly; NSView cacheDisplay omits its composited layers on some macOS versions.
                // Native editor/toggle controls use value representations because ImageRenderer cannot draw their AppKit views.
                let renderer = ImageRenderer(content: CorrectionSettingsView(service: service, snapshot: true)
                    .frame(width: 540).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
                renderer.scale = 2
                guard let cgImage = renderer.cgImage,
                      let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { exit(1) }
                do { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
                catch { fputs("\(error)\n", stderr); exit(1) }
            }
            // Render our own view for layout QA, without reading any other app or screen.
            self.window.appearance = NSAppearance(named: .aqua)
            self.window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let view = self.window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.layoutSubtreeIfNeeded()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                do {
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                    exit(0)
                } catch { fputs("\(error)\n", stderr); exit(1) }
            }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "轻言设置")
        let menu = NSMenu()
        menu.addItem(withTitle: "轻言设置…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "取消录音 / 识别", action: #selector(cancel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出语音辅助应用", action: #selector(quit), keyEquivalent: "").target = self
        statusItem.menu = menu
        if NSApp.isActive { showSettings() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the helper for dictation must not steal focus.
        if sender.isActive { showSettings() }
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        service?.refreshMicrophonePermission()
        if window != nil { showSettings() }
    }
    func applicationWillTerminate(_ notification: Notification) { service?.clearTranscript(); service?.shutdown() }
    @objc func showSettings() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func cancel() { service.cancel() }
    @objc func quit() { NSApp.terminate(nil) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
