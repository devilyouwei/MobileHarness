import CallRuntime
import ExecutionRuntime
import FunctionContracts

/// Host-owned registration profiles, grouped by module rather than model aliases or function lists.
struct BehaviorProtocolBindings {
    enum Error: Swift.Error { case unknownModule(ActionIdentifier) }
    static func bind(_ function: ActionFunction) throws -> ActionBinding {
        let group = function.path.domain + "." + function.path.module
        switch group {
        case "UI.Expression", "Speech.Playback", "NexArm.Motion", "NexArm.Gesture":
            return ActionBinding(function: function)
        case "History.Conversation", "System.Runtime", "System.ModelResources", "System.Provider",
            "UI.ResourcePresentation", "Camera.Capture", "UI.Navigation", "System.Device":
            return ActionBinding(
                function: function, protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning)
        case "UI.Gaze", "UI.Caption", "UI.VoiceState", "UI.Pose", "UI.HistoryPresentation",
            "NexArm.Tracking":
            return ActionBinding(function: function, protocols: [.tool], executionPolicy: .direct)
        default:
            throw Error.unknownModule(function.path)
        }
    }
}
