#if os(iOS)
    import Actions
    import Foundation
    import FunctionContracts
    import UI

    /// UI effect endpoint; owns presentation fences and actual renderer acknowledgments.
    @MainActor public final class ConversationPresentationController {
        public var conversationPresentation = ConversationPresentation()
        private let phaseChanged: @MainActor (VoicePhase) -> Void
        private let state: any ConversationPresenting
        private var token: UIPresentationToken?
        private let effects: any HomeEffectsPresenting
        private let acceptsSession: @MainActor (String) -> Bool
        private let captureAvailable: @MainActor () -> Bool
        private let handlingTurn: @MainActor () -> Bool
        private let expressions: any ExpressionPresenting
        public init(
            state: any ConversationPresenting, effects: any HomeEffectsPresenting,
            expressions: any ExpressionPresenting,
            acceptsSession: @escaping @MainActor (String) -> Bool,
            captureAvailable: @escaping @MainActor () -> Bool,
            handlingTurn: @escaping @MainActor () -> Bool, phaseChanged: @escaping @MainActor (VoicePhase) -> Void
        ) {
            self.state = state
            token = state.token
            self.expressions = expressions
            self.effects = effects
            self.acceptsSession = acceptsSession
            self.captureAvailable = captureAvailable
            self.handlingTurn = handlingTurn
            self.phaseChanged = phaseChanged
        }
        public func beginPresentationSession() { token = state.token }
        private func acceptPresentation(_ context: ActionExecutionContext, update: ConversationPresentation.Update)
            -> Bool
        {
            guard state.accepts(token) else { return false }
            return conversationPresentation.accept(context, update: update, state: state)
        }

        public func presentTranscript(_ text: String, invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            try state.requirePresentation()
            guard state.accepts(token) else { throw CancellationError() }
            guard state.isVoiceActive, acceptsSession(invocation.context.sessionID) else { throw CancellationError() }
            guard acceptPresentation(invocation.context, update: .transcript) else { return }
            state.presentTranscript(text)
        }

        public func finishTranscript(invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            try state.requirePresentation()
            guard state.accepts(token) else { throw CancellationError() }
            guard acceptsSession(invocation.context.sessionID) else { throw CancellationError() }
            guard acceptPresentation(invocation.context, update: .finishTranscript) else { return }
            state.finishUserTranscript()
        }

        public func beginReplyTurn(invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            try state.requirePresentation()
            guard state.accepts(token) else { throw CancellationError() }
            guard state.isVoiceActive, acceptsSession(invocation.context.sessionID) else { throw CancellationError() }
            guard acceptPresentation(invocation.context, update: .beginReply) else { return }
            effects.replyDidBegin()
            state.beginReply()
            resetExpression()
        }

        public func presentVoiceState(_ voiceState: UIActions.VoiceState, invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            try state.requirePresentation()
            guard state.accepts(token) else { throw CancellationError() }
            guard acceptsSession(invocation.context.sessionID) else { throw CancellationError() }
            // In-flight perception Tools cannot restore listening after capture admission has closed.
            guard captureAvailable() else { throw CancellationError() }
            // A late perception update must not reopen listening between model rounds or during playback.
            if handlingTurn(), voiceState == .listening || voiceState == .hearing { return }
            if conversationPresentation.isRecognitionCurrent(invocation.context),
                conversationPresentation.transcriptClosed,
                voiceState != .listening
            {
                return
            }
            guard acceptPresentation(invocation.context, update: .voiceState) else { return }
            switch voiceState {
            case .processing:
                phaseChanged(.processing)
                state.presentVoiceStatus("正在识别 · 暂停接收新语句", clearMicrophone: true)
            case .hearing:
                phaseChanged(.listening)
                state.presentVoiceStatus("检测到语音 · 等待停顿")
            case .listening:
                phaseChanged(.listening)
                state.presentVoiceStatus("正在聆听 · 停顿后自动识别")
            }
        }

        public func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            try state.requirePresentation()
            guard state.accepts(token) else { throw CancellationError() }
            guard acceptsSession(invocation.context.sessionID) else { throw CancellationError() }
            guard acceptPresentation(invocation.context, update: .expression) else {
                throw CancellationError()
            }
            expressions.setBase(emotion == .clear ? nil : EyeExpression(emotion))
        }
        public func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            try state.requirePresentation()
            guard state.accepts(token) else { throw CancellationError() }
            guard acceptsSession(invocation.context.sessionID),
                acceptPresentation(invocation.context, update: .expression)
            else { throw CancellationError() }
            do {
                try await expressions.perform(EyeExpression(emotion), owner: invocation.executionID)
            } catch ConversationExpressionError.busy {
                throw UIActions.ExpressionError.busy
            } catch ConversationExpressionError.rendererUnavailable {
                throw UIActions.ExpressionError.rendererUnavailable
            }
        }
        public func restoreExpression(invocation: any FunctionInput) async throws {
            do {
                try await expressions.restore(
                    owner: invocation.executionID,
                    accepts: acceptsSession(invocation.context.sessionID)
                        && conversationPresentation.isCurrent(invocation.context))
            } catch ConversationExpressionError.busy {
                throw UIActions.ExpressionError.busy
            } catch ConversationExpressionError.rendererUnavailable {
                throw UIActions.ExpressionError.rendererUnavailable
            }
        }
        public func resetExpression() { expressions.resetExpression() }

        public func present(_ text: String, invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            try state.requirePresentation()
            guard state.accepts(token) else { throw CancellationError() }
            guard state.isVoiceActive, acceptsSession(invocation.context.sessionID) else { throw CancellationError() }
            guard acceptPresentation(invocation.context, update: .reply) else { return }
            effects.replyDidBegin()
            state.appendReply(text)
        }

    }
#endif
