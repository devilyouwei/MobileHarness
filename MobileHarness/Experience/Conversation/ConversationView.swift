import SwiftUI

@MainActor
struct ConversationView: View {
    @Bindable var runtime: ConversationViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width * 0.84, 360.0)
            ZStack {
                Color.clear
                Button {
                    runtime.toggleVoice()
                } label: {
                    VoiceOrb(
                        phase: runtime.voicePhase,
                        level: runtime.voicePhase == .speaking ? runtime.playbackLevel : runtime.audioLevel,
                        reduceMotion: reduceMotion,
                        expression: runtime.expression,
                        expressionID: runtime.expressionID
                    )
                    .frame(width: diameter, height: diameter)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!runtime.isReady)
                .accessibilityLabel(runtime.isVoiceActive ? "关闭录音" : "开启录音")
                .accessibilityValue(accessibilityState + (runtime.expression.map { "，表情：" + $0 } ?? ""))
                .accessibilityHint("轻点圆形任意位置。再次轻点会停止录音和语音播放。")
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.42)

                VStack(spacing: 20) {
                    if runtime.voicePhase == .failed {
                        Text(runtime.voiceStatus)
                            .font(.callout).foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                    } else if !runtime.assistantReply.isEmpty {
                        FadingCaption(text: runtime.assistantReply, reduceMotion: reduceMotion)
                            .id("assistant")
                    } else if !runtime.liveTranscript.isEmpty {
                        FadingCaption(text: runtime.liveTranscript, reduceMotion: reduceMotion)
                            .id("transcript")
                    } else {
                        Text(hint)
                            .font(.subheadline).tracking(1)
                            .foregroundStyle(.white.opacity(0.45))
                            .transition(.opacity)
                    }
                }
                .frame(width: min(geometry.size.width - 56, 440), height: geometry.size.height * 0.24)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.74)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: runtime.voicePhase)
            }
        }
        .preferredColorScheme(.dark)
        .task { await runtime.run() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { runtime.stopVoice(message: "已进入后台，轻触重新开始") }
        }
    }

    private var hint: String {
        switch runtime.voicePhase {
        case .idle: "轻触，开始聆听"
        case .loading: "正在唤醒"
        case .listening: "我在听"
        case .processing: "稍等片刻"
        case .speaking: ""
        case .failed: "轻触重试"
        }
    }
    private var accessibilityState: String {
        switch runtime.voicePhase {
        case .idle: "录音已关闭"
        case .loading: "正在加载模型"
        case .listening: "正在聆听"
        case .processing: "正在识别"
        case .speaking: "正在朗读回复"
        case .failed: runtime.voiceStatus
        }
    }
}

/// Startup is presentation-only: the ring has no gesture or button until models are ready.
@MainActor
struct ConversationStartupView: View {
    let status: String
    let error: String?
    let retry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear
                VoiceOrb(phase: error == nil ? .loading : .failed, level: 0, reduceMotion: reduceMotion)
                    .frame(width: min(geometry.size.width * 0.84, 360), height: min(geometry.size.width * 0.84, 360))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.42)
                VStack(spacing: 16) {
                    if let error {
                        Text("模型准备失败：" + error).font(.callout)
                        Button("重新加载", action: retry)
                    } else {
                        ProgressView().tint(.white)
                        Text(status).font(.subheadline)
                    }
                }
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .frame(width: min(geometry.size.width - 56, 440))
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.74)
            }
        }
        .preferredColorScheme(.dark)
    }
}
