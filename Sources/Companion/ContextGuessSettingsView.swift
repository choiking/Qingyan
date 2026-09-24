import SwiftUI
import AppKit

struct ContextGuessSettingsView: View {
    @ObservedObject var service: VoiceService
    @ObservedObject var guesser: ContextGuessService
    @State private var shortcutStatus: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("猜你想说", systemImage: "text.bubble").font(.title2.bold())
                Text("在输入框中按 \(service.settings.guessShortcut.displayName)，轻言读取当前窗口的内容，用本机模型猜你想输入的话，显示在候选面板中。不按就不读取。")
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("微信里对方问「周六下午有空吗？一起去打羽毛球吧」\n→ 好的，我周六三点有空 / 可以，一起打羽毛球 …")
                            .lineSpacing(6)
                        Text("高亮的一条会先以下划线预览在输入框里：↑↓ 切换，Enter / Tab 或 1–3 确认（只上屏，不发送），也可点击；Esc、退格或直接打字即撤回。已有文字时只猜后半句。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Toggle("启用猜你想说", isOn: $service.settings.contextGuessEnabled)
                    .onChange(of: service.settings.contextGuessEnabled) {
                        service.saveSettings()
                        if service.settings.contextGuessEnabled { service.prepareCorrection() }
                    }
                Picker("读取方式", selection: $service.settings.contextSource) {
                    Text("自动：先读界面文字，不够再截图").tag(ContextSource.auto.rawValue)
                    Text("仅界面文字（辅助功能）").tag(ContextSource.accessibility.rawValue)
                    Text("仅截图识别（屏幕录制）").tag(ContextSource.screenshot.rawValue)
                }.onChange(of: service.settings.contextSource) { service.saveSettings() }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("猜测快捷键")
                        Spacer()
                        ShortcutRecorder(shortcut: service.settings.guessShortcut, label: "猜你想说快捷键", allowsModifierKeys: false,
                            conflict: { $0 == service.settings.voiceShortcut ? "这组按键已用于语音输入，请换一组。" : nil },
                            savedMessage: { "已保存：在输入框中按 \($0.displayName) 开始猜测。" },
                            onSave: { service.setGuessShortcut($0) }, onStatus: { shortcutStatus = $0 })
                            .frame(width: 180, height: 28)
                        Button("恢复默认") {
                            if service.setGuessShortcut(.defaultGuessShortcut) { shortcutStatus = "已恢复 ⌃⌥G。" }
                        }.disabled(service.settings.guessShortcut == .defaultGuessShortcut)
                    }
                    Text(shortcutStatus ?? "按下后先显示「正在猜你想说」，约一两秒出结果；没有猜到时会说明原因。也可在输入法菜单中选择「猜我想说」。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.disabled(!service.settings.contextGuessEnabled)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        permission("辅助功能", detail: "读取当前窗口的文字。在系统设置中允许「轻言语音」。",
                                   granted: guesser.accessibilityGranted, pane: "Privacy_Accessibility", app: Bundle.main.bundleURL) {
                            ContextReader.requestAccessibility()
                        }
                        Divider()
                        permission("屏幕录制", detail: "截取当前窗口，用 macOS 自带的文字识别读取。微信等界面文字较少的应用需要它。",
                                   granted: guesser.screenGranted, pane: "Privacy_ScreenCapture", app: inputMethodURL) {
                            ContextReader.requestScreen()
                        }
                        Text("屏幕录制通常列在「轻言输入法」名下。若列表显示旧日期，或开关已开启却仍未授权，请移除旧条目，点对应的「显示应用」，将应用重新添加到权限列表。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("刷新权限") { guesser.refreshPermissions() }
                            Button("退出辅助应用") { NSApp.terminate(nil) }.disabled(service.busy || guesser.testing)
                        }
                        Text("授权屏幕录制后可能需要退出辅助应用，再切回输入框；轻言会自动重新启动它。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                HStack {
                    Text("模型：\(service.correctionStatus)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if service.preparingCorrection || guesser.testing { ProgressView().controlSize(.small) }
                    Button("检查模型") { service.prepareCorrection() }.disabled(service.preparingCorrection)
                    Button(guesser.testing ? "测试中…" : "测试示例") { guesser.testExample() }
                        .disabled(guesser.testing || service.preparingCorrection)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("最近一次").font(.headline)
                        Text(guesser.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        if !guesser.lastContext.isEmpty { Button("清除") { guesser.clear() } }
                    }
                    if !guesser.lastSuggestions.isEmpty {
                        Text(guesser.lastSuggestions.map { "✦ " + $0 }.joined(separator: "\n")).textSelection(.enabled)
                    }
                    if !guesser.lastContext.isEmpty {
                        ScrollView { Text(guesser.lastContext).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(height: 90).padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Text("读取和推测都在这台 Mac 上完成：截图只在内存中识别，不保存、不上传；使用与语音纠错相同的本机 Qwen3 4B。有应用正在输入密码时不读取。最近一次读到的内容在此保留最多 10 分钟，便于核对。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(28)
        }
        .onAppear { guesser.refreshPermissions() }
    }
    private var inputMethodURL: URL {
        let outer = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: outer)?.bundleIdentifier == "org.localinput.inputmethod.LocalInput" ? outer : Bundle.main.bundleURL
    }
    private func permission(_ title: String, detail: String, granted: Bool, pane: String, app: URL, request: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted { Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.teal) }
            else {
                VStack(alignment: .trailing, spacing: 6) {
                    Button("授权…") {
                        request()
                        guesser.refreshPermissions()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    }
                    Button("显示应用") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                }
            }
        }
    }
}
