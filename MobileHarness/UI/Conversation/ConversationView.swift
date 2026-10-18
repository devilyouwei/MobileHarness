import Foundation

#if os(iOS)
    import SwiftUI

    /// Keep caption observation outside the native effects surface's update inputs.
    @MainActor
    private struct ConversationCompanion: View {
        let state: ConversationState
        let reduceMotion: Bool
        @Environment(\.eyeGaze) private var gaze
        let faceWidth: CGFloat
        let eyeCenter: CGPoint
        let held: Bool
        var body: some View {
            NativeCompanionSurface(
                phase: state.voicePhase, reduceMotion: reduceMotion,
                expression: state.displayedExpression, emphasized: state.expressionEmphasized,
                transitionID: state.expressionTransitionID, gaze: gaze,
                faceWidth: faceWidth, eyeCenter: eyeCenter,
                active: state.isVoiceActive, generation: state.listeningAnimationID,
                lightOrigin: state.listeningLightOrigin, decorativeLight: state.decorativeLight, held: held,
                completion: { state.expressionAnimationCompletion?($0, $1) },
                availability: { available in
                    state.expressionRendererAvailable = available
                    if !available, let id = state.expressionTransitionID {
                        state.expressionAnimationCompletion?(id, false)
                    }
                }, failure: { state.graphicsMessage = $0 }
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @MainActor
    private struct ConversationVoiceBars: View {
        let state: ConversationState
        let placement: VoiceBars.Placement
        let reduceMotion: Bool
        var body: some View {
            VoiceBars(
                placement: placement,
                bands: placement == .bottom ? state.microphoneSpectrum : state.playbackSpectrum,
                active: state.voicePhase == (placement == .bottom ? .listening : .speaking),
                reduceMotion: reduceMotion)
        }
    }

    @MainActor
    public struct ConversationView: View {
        @Bindable var state: ConversationState
        @Bindable var activity: ActionActivityState
        private let toggleVoice: () -> Void
        private let voicePressChanged: ((Bool) -> Void)?
        public init(
            state: ConversationState, activity: ActionActivityState,
            toggleVoice: @escaping () -> Void, voicePressChanged: ((Bool) -> Void)? = nil
        ) {
            self.state = state
            self.activity = activity
            self.toggleVoice = toggleVoice
            self.voicePressChanged = voicePressChanged
        }
        @GestureState private var holdingVoice = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        public var body: some View {
            GeometryReader { geometry in
                let diameter = min(geometry.size.width * 0.84, 360.0)
                ZStack {
                    ConversationAtmosphere()
                    ConversationCompanion(
                        state: state, reduceMotion: reduceMotion,
                        faceWidth: min(geometry.size.width, 600),
                        eyeCenter: CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.40),
                        held: holdingVoice)
                    Circle().fill(.clear)
                        .frame(width: diameter, height: diameter)
                        .contentShape(Circle())
                        .gesture(
                            LongPressGesture(minimumDuration: 0.5, maximumDistance: 24)
                                .updating($holdingVoice) { pressing, held, _ in held = pressing }
                                .onEnded { _ in if state.isReady { toggleVoice() } }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { touch in
                                    guard state.isReady else { return }
                                    voicePressChanged?(true)
                                    let origin = ListeningLightOrigin(
                                        x: (touch.startLocation.x + (geometry.size.width - diameter) / 2)
                                            / geometry.size.width,
                                        y: (touch.startLocation.y + geometry.size.height * 0.40 - diameter / 2)
                                            / geometry.size.height)
                                    if state.listeningLightOrigin != origin { state.listeningLightOrigin = origin }
                                }
                                .onEnded { _ in voicePressChanged?(false) }
                        )
                        .allowsHitTesting(state.isReady)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            if state.isReady {
                                state.listeningLightOrigin = nil
                                toggleVoice()
                            }
                        }
                        .accessibilityLabel(state.isVoiceActive || state.isReplyActive ? "停止聆听与回复" : "开启聆听")
                        .accessibilityValue(accessibilityState + "，表情：" + state.displayedExpression.rawValue)
                        .accessibilityHint("按住双眼半秒开启聆听，松开后继续聆听。再次按住关闭录音。")
                        .accessibilityIdentifier("conversation.voiceHold")
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.40)

                    Group {
                        let layout = ConversationCaptionLayout(
                            viewportHeight: geometry.size.height, faceDiameter: diameter,
                            hasTranscript: !state.liveTranscript.isEmpty, finalized: state.transcriptFinalized,
                            hasTask: activity.currentTaskID != nil, hasActivity: !activity.items.isEmpty)
                        if activity.currentTaskID != nil {
                            Label {
                                Text("任务：" + activity.currentTaskTitle)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            } icon: {
                                Image(systemName: "scope").accessibilityHidden(true)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(height: 18)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("当前任务：" + activity.currentTaskTitle)
                            .accessibilityIdentifier("conversation.currentTask")
                            .allowsHitTesting(false)
                            .frame(width: min(geometry.size.width - 56, 440))
                            .position(x: geometry.size.width / 2, y: layout.taskCenterY)
                        }
                        FadingCaption(
                            text: state.liveTranscript, reduceMotion: reduceMotion, color: .cyan,
                            finalized: state.transcriptFinalized
                        )
                        .accessibilityLabel("用户输入：" + state.liveTranscript)
                        .allowsHitTesting(!state.liveTranscript.isEmpty)
                        .opacity(
                            ConversationCaptionVisibility.user(
                                isListening: state.isVoiceActive, finalized: state.transcriptFinalized,
                                hasNotice: activity.visibleNotice != nil) ? 1 : 0
                        )
                        .accessibilityHidden(
                            state.liveTranscript.isEmpty
                                || !ConversationCaptionVisibility.user(
                                    isListening: state.isVoiceActive, finalized: state.transcriptFinalized,
                                    hasNotice: activity.visibleNotice != nil)
                        )
                        .frame(width: min(geometry.size.width - 56, 440), height: layout.captionHeight)
                        .position(x: geometry.size.width / 2, y: layout.captionCenterY)
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.9),
                            value: state.transcriptFinalized)
                    }

                    VStack(spacing: 20) {
                        if let message = state.graphicsMessage {
                            Text(message).font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                        let showsReply =
                            state.voicePhase != .failed && state.listeningControlMessage == nil
                            && state.isVoiceActive && !state.assistantReply.isEmpty
                        ZStack {
                            // Stable identity: native text surfaces mount before the first recognition/reply.
                            FadingCaption(
                                text: state.assistantReply, reduceMotion: reduceMotion,
                                color: Color(red: 0.83, green: 0.74, blue: 1)
                            )
                            .accessibilityLabel("assistant 回复：" + state.assistantReply)
                            .opacity(showsReply ? state.assistantReplyOpacity : 0)
                            .accessibilityHidden(!showsReply)
                            .allowsHitTesting(showsReply)
                            .animation(
                                reduceMotion ? nil : .easeOut(duration: 0.35), value: state.assistantReplyOpacity)
                            if state.voicePhase == .failed || state.listeningControlMessage != nil {
                                Text(state.listeningControlMessage ?? state.voiceStatus)
                                    .font(.callout).foregroundStyle(.white.opacity(0.72))
                                    .multilineTextAlignment(.center)
                            } else if !showsReply && (state.liveTranscript.isEmpty || state.transcriptFinalized) {
                                Text(hint)
                                    .font(.subheadline).tracking(1)
                                    .foregroundStyle(.white.opacity(0.45))
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: min(geometry.size.width - 56, 440), height: min(120, geometry.size.height * 0.20))
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height - (activity.items.isEmpty ? 120 : 240)
                    )
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state.voicePhase)
                    .opacity(ConversationCaptionVisibility.reply(hasNotice: activity.visibleNotice != nil) ? 1 : 0)
                    .accessibilityHidden(activity.visibleNotice != nil)

                    if let issue = activity.visibleNotice {
                        (Text(
                            Image(
                                systemName: issue.tone == .info ? "info.circle.fill" : "exclamationmark.triangle.fill"))
                            + Text(" " + issue.text))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(issue.tone == .info ? .cyan : .yellow)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .frame(width: min(geometry.size.width - 56, 440), height: 56)
                            .accessibilityLabel(issue.text)
                            .accessibilityIdentifier("conversation.errorToast")
                            .allowsHitTesting(false)
                            .position(
                                x: geometry.size.width / 2,
                                y: geometry.size.height - (activity.items.isEmpty ? 120 : 240)
                            )
                            .transition(.opacity)

                    }

                    ConversationVoiceBars(state: state, placement: .bottom, reduceMotion: reduceMotion)
                        .frame(width: geometry.size.width, height: 100 + geometry.safeAreaInsets.bottom)
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height + geometry.safeAreaInsets.bottom / 2 - 50)
                    ConversationVoiceBars(state: state, placement: .reply, reduceMotion: reduceMotion)
                        .frame(width: 166, height: 62)
                        .position(
                            x: geometry.size.width / 2,
                            y: replySpectrumY(in: geometry)
                        )
                        .opacity(state.voicePhase == .speaking ? 1 : 0)
                    VStack {
                        Spacer(minLength: 0)
                        if activity.hasRecords || activity.observationUnavailable {
                            ActionActivityView(state: activity)
                        }
                    }
                    .frame(width: geometry.size.width - 40)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                }
            }
            .onChange(of: state.liveTranscript) { _, text in
                if !text.isEmpty && !state.transcriptFinalized, let issue = activity.errorToast {
                    activity.dismissErrorToast(id: issue.id)
                }
            }
            .onDisappear { voicePressChanged?(false) }
            .preferredColorScheme(.dark)
        }
        private var hint: String {
            switch state.voicePhase {
            case .idle: "按住，开启聆听"
            case .loading: "正在唤醒"
            case .listening: "我在听"
            case .processing: "稍等片刻"
            case .speaking: ""
            case .failed: "按住重试"
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
                        phase: error == nil ? .loading : .failed, reduceMotion: reduceMotion, expression: .closed,
                        gaze: eyeGaze,
                        faceWidth: min(geometry.size.width, 600)
                    )
                    .frame(width: min(geometry.size.width * 0.84, 360), height: min(geometry.size.width * 0.84, 360))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.40)
                    VStack(spacing: 16) {
                        if let error {
                            Text("应用准备失败：" + error).font(.callout)
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
                        x: geometry.size.width / 2,
                        y: geometry.size.height - min(120, geometry.size.height * 0.20))
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

    /// Public safe-area estimate: typical island lower edge is about 12 pt above its safe-area bottom.
    /// The 62 pt surface reserves 24 pt above its lower-edge baseline for the bowl corners.
    /// Bars overlap the estimated edge by one point. Non-island layouts stay inside the safe area.
    @MainActor
    private func replySpectrumY(in geometry: GeometryProxy) -> CGFloat {
        let islandLayout = geometry.safeAreaInsets.top >= 59 && geometry.size.width < 600
        return islandLayout ? 31 - 24 - 13 : 31
    }

#endif
