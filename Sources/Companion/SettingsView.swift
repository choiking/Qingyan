import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var service: VoiceService
    @State private var shortcutStatus: String?
    var body: some View {
        TabView {
            general.tabItem { Text("输入与语音") }
            JevSettingsView(service: service).tabItem { Text("Jev 选词") }
            CorrectionSettingsView(service: service).tabItem { Text("语音纠错") }
        }.padding(8).frame(width: 540, height: 700)
    }
    private var general: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 48)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("轻言输入法").font(.system(size: 30, weight: .semibold))
                    Text("Qingyan · 想说就说，想打就打。").foregroundStyle(.secondary)
                }
                Spacer()
                Text("本地优先").font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.teal.opacity(0.1), in: Capsule()).foregroundStyle(.teal)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("开始使用", systemImage: "keyboard") .font(.headline)
                    Text("1. 在系统设置中添加「轻言输入法」输入源。\n2. 单按 Shift 切换中 / 英文；切到英文时，未确认内容按原始字母输入。\n3. 按住 \(service.settings.voiceShortcut.displayName) 说话，文字实时显示，松开定稿。")
                        .lineSpacing(6).foregroundStyle(.secondary)
                    HStack {
                        Button("打开键盘设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                        Button(service.microphoneButtonTitle) { service.requestMicrophone() }
                            .disabled(service.microphoneGranted || service.requestingMicrophone || service.microphoneStatus == .restricted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("语音快捷键")
                            Spacer()
                            ShortcutRecorder(shortcut: service.settings.voiceShortcut,
                                onSave: { service.setVoiceShortcut($0) }, onStatus: { shortcutStatus = $0 })
                                .frame(width: 180, height: 28)
                            Button("恢复默认") {
                                if service.setVoiceShortcut(.defaultShortcut) { shortcutStatus = "已恢复 ⌃⌥Space。" }
                            }.disabled(service.settings.voiceShortcut == .defaultShortcut)
                        }
                        HStack {
                            Menu("快捷选项") {
                                Button("单键 F5") { setShortcut(VoiceShortcut(keyCode: 96, modifiers: 0)) }
                                Button("右 Option") { setShortcut(VoiceShortcut(keyCode: 61, modifiers: 0, trigger: .modifierPress)) }
                                Button("Fn") { setShortcut(VoiceShortcut(keyCode: 63, modifiers: 0, trigger: .modifierPress)) }
                            }.fixedSize()
                        }
                        Text(shortcutStatus ?? "按住说话，文字在输入框中逐步更新，松开后校正定稿。支持功能键、组合键或单独修饰键；仅在轻言输入法中生效。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if service.settings.voiceShortcut.keyCode == 63 || VoiceShortcut.functionKeys.contains(service.settings.voiceShortcut.keyCode) {
                            Text("Fn / 功能键若被系统占用，请在系统键盘设置中调整对应行为。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(service.busy)
                    Picker("语音语言", selection: $service.settings.language) {
                        Text("自动检测").tag("auto")
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                    }.onChange(of: service.settings.language) { service.saveSettings() }
                    Toggle("单按 Shift 切换中英文", isOn: $service.settings.shiftToggle)
                        .onChange(of: service.settings.shiftToggle) { service.saveSettings() }
                    HStack {
                        Text("候选字号")
                        Slider(value: $service.settings.fontSize, in: 14...26, step: 1)
                            .onChange(of: service.settings.fontSize) { service.saveSettings() }
                        Text("\(Int(service.settings.fontSize))").monospacedDigit().frame(width: 24)
                    }
                    HStack {
                        Text(service.settings.modelPath.isEmpty ? "离线模型：SenseVoice Small · 中英日韩粤 · INT8" : "模型：\(service.modelURL.lastPathComponent)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("选择…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            // SenseVoice ONNX; tokens.txt must sit beside it.
                            panel.allowedContentTypes = UTType(filenameExtension: "onnx").map { [$0] } ?? []
                            if panel.runModal() == .OK, let url = panel.url {
                                service.settings.modelPath = url.path; service.saveSettings()
                            }
                        }.disabled(service.busy)
                        if !service.settings.modelPath.isEmpty {
                            Button("恢复") { service.settings.modelPath = ""; service.saveSettings() }.disabled(service.busy)
                        }
                    }
                }.padding(8)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(service.phase == "recording" ? Color.red : Color.teal).frame(width: 7, height: 7)
                    Text(service.detail).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if ["transcribing", "correcting"].contains(service.phase) { ProgressView().controlSize(.small) }
                }
                if !service.transcript.isEmpty {
                    ScrollView { Text(service.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 72).padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Button(service.phase == "recording" ? "停止并转写" : "测试语音") { service.testRecording() }
                        .buttonStyle(.borderedProminent).tint(.teal)
                        .disabled(service.requestingMicrophone || (service.busy && service.phase != "recording"))
                    if service.busy { Button("取消") { service.cancel() } }
                    if !service.transcript.isEmpty {
                        Button("复制文字") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(service.transcript, forType: .string)
                        }
                        Button("清除") { service.clearTranscript() }
                    }
                    Spacer()
                }
            }
            Spacer(minLength: 0)
            Text("录音仅在内存中处理。最近一次转写在此保留最多 10 分钟，可随时清除。使用系统默认麦克风。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func setShortcut(_ shortcut: VoiceShortcut) {
        if service.setVoiceShortcut(shortcut) { shortcutStatus = nil }
        else { shortcutStatus = "保存失败，请重试。" }
    }
}
