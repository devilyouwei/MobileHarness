#if os(iOS)
    import SwiftUI

    @MainActor
    public struct ConversationView: View {
        @Bindable var state: ConversationState
        @Bindable var robot: BluetoothSettingsState
        private let toggleVoice: () -> Void
        public init(state: ConversationState, robot: BluetoothSettingsState, toggleVoice: @escaping () -> Void) {
            self.state = state
            self.robot = robot
            self.toggleVoice = toggleVoice
        }
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.eyeGaze) private var eyeGaze

        public var body: some View {
            GeometryReader { geometry in
                let diameter = min(geometry.size.width * 0.84, 360.0)
                ZStack {
                    ConversationAtmosphere()
                    Button {
                        toggleVoice()
                    } label: {
                        CompanionEyes(
                            phase: state.voicePhase,
                            reduceMotion: reduceMotion,
                            expression: state.expression,
                            gaze: eyeGaze,
                            faceWidth: min(geometry.size.width, 600)
                        )
                        .frame(width: diameter, height: diameter)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.isReady)
                    .accessibilityLabel(state.isVoiceActive ? "关闭录音" : "开启录音")
                    .accessibilityValue(accessibilityState + (state.expression.map { "，表情：" + $0.rawValue } ?? ""))
                    .accessibilityHint("轻点眼睛区域。再次轻点会停止录音和语音播放。")
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.40)

                    VStack(spacing: 20) {
                        if state.voicePhase == .failed {
                            Text(state.voiceStatus)
                                .font(.callout).foregroundStyle(.white.opacity(0.72))
                                .multilineTextAlignment(.center)
                        } else if !state.assistantReply.isEmpty {
                            FadingCaption(text: state.assistantReply, reduceMotion: reduceMotion)
                                .id("assistant")
                        } else if !state.liveTranscript.isEmpty {
                            FadingCaption(text: state.liveTranscript, reduceMotion: reduceMotion)
                                .id("transcript")
                        } else {
                            Text(hint)
                                .font(.subheadline).tracking(1)
                                .foregroundStyle(.white.opacity(0.45))
                                .transition(.opacity)
                        }
                    }
                    .frame(width: min(geometry.size.width - 56, 440), height: min(120, geometry.size.height * 0.20))
                    .position(
                        x: geometry.size.width / 2, y: geometry.size.height - min(120, geometry.size.height * 0.20)
                    )
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state.voicePhase)

                    if robot.phase == .connected || robot.motionStatus != nil {
                        Label(
                            robot.motionStatus
                                ?? (robot.controlReady ? "\(robot.selected?.name ?? "机械臂") 已连接" : "机械臂已连接，控制待验证"),
                            systemImage: robot.executing
                                ? "arrow.triangle.2.circlepath" : "sensor.tag.radiowaves.forward.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(robot.error == nil ? Color.white.opacity(0.7) : Color.orange)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: min(geometry.size.width - 56, 440))
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 38)
                        .accessibilityIdentifier("conversation.robot.status")
                    }

                    VoiceBars(
                        placement: .bottom, bands: state.microphoneSpectrum,
                        active: state.voicePhase == .listening, reduceMotion: reduceMotion
                    )
                    .frame(width: geometry.size.width, height: 100 + geometry.safeAreaInsets.bottom)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height + geometry.safeAreaInsets.bottom / 2 - 50)
                    VoiceBars(
                        placement: .reply, bands: state.playbackSpectrum,
                        active: state.voicePhase == .speaking, reduceMotion: reduceMotion
                    )
                    .frame(width: 166, height: 62)
                    .position(
                        x: geometry.size.width / 2,
                        y: replySpectrumY(in: geometry)
                    )
                    .opacity(state.voicePhase == .speaking ? 1 : 0)
                }
            }
            .preferredColorScheme(.dark)
        }

        private var hint: String {
            switch state.voicePhase {
            case .idle: "轻触，开始聆听"
            case .loading: "正在唤醒"
            case .listening: "我在听"
            case .processing: "稍等片刻"
            case .speaking: ""
            case .failed: "轻触重试"
            }
        }
        private var accessibilityState: String {
            switch state.voicePhase {
            case .idle: "录音已关闭"
            case .loading: "正在加载模型"
            case .listening: "正在聆听"
            case .processing: "正在识别"
            case .speaking: "正在朗读回复"
            case .failed: state.voiceStatus
            }
        }
    }

    /// Startup eyes stay noninteractive until models are ready.
    @MainActor
    public struct ConversationStartupView: View {
        let status: String
        let error: String?
        let retry: () -> Void
        public init(status: String, error: String?, retry: @escaping () -> Void) {
            self.status = status
            self.error = error
            self.retry = retry
        }
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.eyeGaze) private var eyeGaze

        public var body: some View {
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
                    .position(
                        x: geometry.size.width / 2, y: geometry.size.height - min(120, geometry.size.height * 0.20))
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    /// Leaves the existing camera visible, with a quiet navy veil for contrast.
    @MainActor
    private struct ConversationAtmosphere: View {
        public var body: some View {
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

    #Preview("视觉演示 · 聆听与回应（模拟频谱）") {
        ConversationVisualPreview()
    }

    /// Isolated design preview: never opens the microphone, camera or model runtime.
    @MainActor
    public struct ConversationVisualPreview: View {
        public init() {}
        @State private var speaking = ProcessInfo.processInfo.arguments.contains("-preview-speaking")
        @State private var expression: EyeExpression = .clear
        @State private var tone = 500.0
        private var previewBands: [Float] {
            // Explicit visual-only spectrum; no audio device or model is created by previews.
            (0..<32).map { index in
                let frequency = 60 * pow(100, Double(index) / 31)
                let distance = log2(frequency / tone)
                return Float(0.85 * exp(-distance * distance * 8))
            }
        }
        public var body: some View {
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
                        Text("视觉演示 · 模拟频谱，不播放音频").font(.caption2).foregroundStyle(.gray)
                        Slider(value: $tone, in: 100...6000)
                            .frame(width: 220).accessibilityLabel("模拟频率")
                        Button("切换说话", action: { speaking.toggle() }).font(.caption)
                        Picker("眼睛表情", selection: $expression) {
                            ForEach(EyeExpression.allCases, id: \.self) { emotion in
                                Text(emotion.rawValue).tag(emotion)
                            }
                        }.pickerStyle(.menu)
                    }.position(x: geometry.size.width / 2, y: geometry.size.height - 150)
                    VoiceBars(placement: .bottom, bands: previewBands, active: !speaking, reduceMotion: false)
                        .frame(height: 100 + geometry.safeAreaInsets.bottom)
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height + geometry.safeAreaInsets.bottom / 2 - 50)
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

#endif
