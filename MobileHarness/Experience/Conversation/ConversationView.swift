import Actions
import PlatformKit
import SwiftUI

@MainActor
struct ConversationView: View {
    @Bindable var runtime: ConversationViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.eyeGaze) private var eyeGaze

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width * 0.84, 360.0)
            ZStack {
                ConversationAtmosphere()
                Button {
                    runtime.toggleVoice()
                } label: {
                    CompanionEyes(
                        phase: runtime.voicePhase,
                        reduceMotion: reduceMotion,
                        expression: runtime.expression,
                        gaze: eyeGaze,
                        faceWidth: min(geometry.size.width, 600)
                    )
                    .frame(width: diameter, height: diameter)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!runtime.isReady)
                .accessibilityLabel(runtime.isVoiceActive ? "关闭录音" : "开启录音")
                .accessibilityValue(accessibilityState + (runtime.expression.map { "，表情：" + $0.rawValue } ?? ""))
                .accessibilityHint("轻点眼睛区域。再次轻点会停止录音和语音播放。")
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.40)

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
                .frame(width: min(geometry.size.width - 56, 440), height: min(120, geometry.size.height * 0.20))
                .position(x: geometry.size.width / 2, y: geometry.size.height - min(120, geometry.size.height * 0.20))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: runtime.voicePhase)

                VoiceBars(
                    placement: .bottom, bands: runtime.microphoneSpectrum,
                    active: runtime.voicePhase == .listening, reduceMotion: reduceMotion
                )
                .frame(width: geometry.size.width, height: 100 + geometry.safeAreaInsets.bottom)
                .position(
                    x: geometry.size.width / 2,
                    y: geometry.size.height + geometry.safeAreaInsets.bottom / 2 - 50)
                VoiceBars(
                    placement: .reply, bands: runtime.playbackSpectrum,
                    active: runtime.voicePhase == .speaking, reduceMotion: reduceMotion
                )
                .frame(width: 166, height: 62)
                .position(
                    x: geometry.size.width / 2,
                    y: replySpectrumY(in: geometry)
                )
                .opacity(runtime.voicePhase == .speaking ? 1 : 0)
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

/// Startup eyes stay noninteractive until models are ready.
@MainActor
struct ConversationStartupView: View {
    let status: String
    let error: String?
    let retry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.eyeGaze) private var eyeGaze

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ConversationAtmosphere()
                CompanionEyes(
                    phase: error == nil ? .loading : .failed, reduceMotion: reduceMotion, gaze: eyeGaze,
                    faceWidth: min(geometry.size.width, 600)
                )
                .frame(width: min(geometry.size.width * 0.84, 360), height: min(geometry.size.width * 0.84, 360))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.40)
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
                .position(x: geometry.size.width / 2, y: geometry.size.height - min(120, geometry.size.height * 0.20))
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Leaves the existing camera visible, with a quiet navy veil for contrast.
@MainActor
private struct ConversationAtmosphere: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.015, green: 0.035, blue: 0.075).opacity(0.82),
                .black.opacity(0.45), Color(red: 0.01, green: 0.025, blue: 0.055).opacity(0.9),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview("视觉演示 · 聆听与回应（测试音频谱）") {
    ConversationVisualPreview()
}

/// Isolated design preview: never opens the microphone, camera or model runtime.
@MainActor
struct ConversationVisualPreview: View {
    @State private var speaking = ProcessInfo.processInfo.arguments.contains("-preview-speaking")
    @State private var expression: UIActions.Emotion = .clear
    @State private var tone = 500.0
    private var previewBands: [Float] {
        let samples = (0..<AudioSpectrum.sampleCount).map { index in
            Float(0.12 * sin(2 * Double.pi * tone * Double(index) / 16000))
        }
        return AudioSpectrum.measure(samples, sampleRate: 16000)
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                ConversationAtmosphere()
                CompanionEyes(
                    phase: speaking ? .speaking : .listening, reduceMotion: false, expression: expression,
                    faceWidth: min(geometry.size.width, 600)
                )
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.40)
                VoiceBars(placement: .reply, bands: previewBands, active: speaking, reduceMotion: false)
                    .frame(width: 166, height: 62)
                    .position(x: geometry.size.width / 2, y: replySpectrumY(in: geometry))
                    .opacity(speaking ? 1 : 0)
                VStack(spacing: 18) {
                    Text(speaking ? "好呀，我们一起出发。" : "今天，想和你一起去看海")
                        .foregroundStyle(.white)
                    Text("视觉演示 · 合成测试音频谱").font(.caption2).foregroundStyle(.gray)
                    Slider(value: $tone, in: 100...6000)
                        .frame(width: 220).accessibilityLabel("测试音频率")
                    Button("切换说话", action: { speaking.toggle() }).font(.caption)
                    Picker("眼睛表情", selection: $expression) {
                        ForEach(UIActions.Emotion.allCases, id: \.self) { emotion in
                            Text(emotion.rawValue).tag(emotion)
                        }
                    }.pickerStyle(.menu)
                }.position(x: geometry.size.width / 2, y: geometry.size.height - 150)
                VoiceBars(placement: .bottom, bands: previewBands, active: !speaking, reduceMotion: false)
                    .frame(height: 100 + geometry.safeAreaInsets.bottom)
                    .position(
                        x: geometry.size.width / 2, y: geometry.size.height + geometry.safeAreaInsets.bottom / 2 - 50)
            }
        }.preferredColorScheme(.dark)
    }
}

/// Public safe-area estimate: typical island lower edge is about 12 pt above its safe-area bottom.
/// The 62 pt canvas reserves 24 pt above its lower-edge baseline for the bowl corners.
/// Bars overlap the estimated edge by one point. Non-island layouts stay inside the safe area.
@MainActor
private func replySpectrumY(in geometry: GeometryProxy) -> CGFloat {
    let islandLayout = geometry.safeAreaInsets.top >= 59 && geometry.size.width < 600
    return islandLayout ? 31 - 24 - 13 : 31
}
