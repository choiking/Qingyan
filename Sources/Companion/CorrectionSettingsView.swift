import SwiftUI
import AppKit

struct CorrectionSettingsView: View {
    @ObservedObject var service: VoiceService
    var snapshot = false
    var body: some View {
        if snapshot { content }
        else { ScrollView { content } }
    }
    private var content: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("让识别更准确").font(.title2.weight(.semibold))
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("常用词提示", systemImage: "character.book.closed").font(.headline)
                        Text("填写人名、产品名或专业词汇，帮助语音识别选择正确写法。不会强制替换相似词语。")
                            .font(.callout).foregroundStyle(.secondary)
                        Group {
                            if snapshot {
                                Text(service.settings.voiceVocabulary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            } else { TextEditor(text: $service.settings.voiceVocabulary) }
                        }
                            .font(.body).frame(height: 105).padding(6)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            .onChange(of: service.settings.voiceVocabulary) {
                                if service.settings.voiceVocabulary.count > 4000 {
                                    service.settings.voiceVocabulary = String(service.settings.voiceVocabulary.prefix(4000))
                                }
                                service.saveSettings()
                            }
                        Text("每行一个，最多 40 个，每个不超过 40 字，总计最多 400 字。当前有效：\(VoiceVocabulary.normalize(service.settings.voiceVocabulary).count) 个 · 自动保存")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.disabled(service.busy)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Group {
                            if snapshot {
                                Label("本地 AI 轻度纠错", systemImage: service.settings.correctionEnabled ? "checkmark.square.fill" : "square")
                            } else { Toggle("本地 AI 轻度纠错", isOn: $service.settings.correctionEnabled) }
                        }
                            .font(.headline).disabled(service.busy)
                            .onChange(of: service.settings.correctionEnabled) {
                                service.saveSettings()
                                if service.settings.correctionEnabled { service.prepareCorrection() }
                            }
                        Text("边说边显示；松开后检查错字和标点，不润色、不扩写。纠错最多等待 4 秒，失败或改动过大时保留原文。")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Text(service.correctionStatus).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if service.preparingCorrection { ProgressView().controlSize(.small) }
                            Button("检查模型") { service.prepareCorrection() }.disabled(service.preparingCorrection || service.busy)
                        }
                        Text("开始打字会停止等待并保留原文。纠错上屏后，立即按 Esc 恢复原文；继续输入或切换窗口后，请在下方复制原文。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if !service.originalTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("最近一次识别原文").font(.headline)
                            Spacer()
                            Button("复制原文") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(service.originalTranscript, forType: .string)
                            }
                            Button("清除") { service.clearTranscript() }.disabled(service.busy)
                        }
                        Text(service.originalTranscript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if service.transcript != service.originalTranscript {
                            Text("纠错结果").font(.headline).padding(.top, 4)
                            Text(service.transcript).textSelection(.enabled)
                        }
                    }.padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("语音和纠错文字只在这台 Mac 处理。AI 仍可能改错，请核对重要内容。原文与结果在此保留最多 10 分钟，不记录历史。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).groupBoxStyle(CorrectionGroupStyle())
    }
}

private struct CorrectionGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }
}
