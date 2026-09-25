#if !canImport(CoreAI)
    import Foundation
    import ModelKit

    /// Simulator SDKs without CoreAI report unavailable; never substitute synthetic recognition.
    @available(iOS 27, macOS 27, *)
    public actor NemotronASR: SpeechRecognitionCapability {

        public init(context: ModelContext, artifacts: URL) throws {
            let _: ModelResource<Void> = try context.resource {
                throw CapabilityError.unavailable("This SDK/runtime has no CoreAI")
            }
        }
        public var availability: CapabilityAvailability { .unavailable(reason: "This SDK/runtime has no CoreAI") }
        public func warmup() async throws { throw CapabilityError.unavailable("This SDK/runtime has no CoreAI") }
        public func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
            throw CapabilityError.unavailable("This SDK/runtime has no CoreAI")
        }
    }
#endif
