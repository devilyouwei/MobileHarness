import CallRuntime
import ExecutionRuntime
import FunctionContracts

/// Host-owned registration profiles, grouped by module rather than model aliases or function lists.
struct BehaviorProtocolBindings {
    enum Error: Swift.Error { case unknownModule(ActionIdentifier) }
    static func bind(_ function: ActionFunction) throws -> ActionBinding {
        if (function.path.domain == "Camera" && function.path.module == "Capture")
            || (function.path.domain == "UI" && function.path.module == "Navigation")
            || (function.path.domain == "System" && function.path.module == "Device"
                && function.path.function == "readEnvironment")
        {
            return ActionBinding(
                function: function, protocols: [.action, .tool], executionPolicy: .direct,
                directResultPolicy: .returning, feedbackPolicy: .observation)
        }
        let group = function.path.domain + "." + function.path.module
        if group == "UI.Caption", ["print", "beginReplyTurn"].contains(function.path.function) {
            return ActionBinding(function: function, protocols: [.action, .tool], executionPolicy: .direct)
        }
        switch group {
        case "UI.Expression", "Speech.Playback", "Speech.Listening", "NexArm.Motion", "NexArm.Gesture":
            return ActionBinding(function: function)
        case "History.Conversation", "System.Runtime", "System.ModelResources", "System.Provider",
            "UI.ResourcePresentation", "System.Device":
            return ActionBinding(
                function: function, protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning,
                feedbackPolicy: .observation)
        case "UI.Gaze", "UI.Caption", "UI.VoiceState", "UI.Pose", "UI.HistoryPresentation",
            "NexArm.Tracking":
            return ActionBinding(function: function, protocols: [.tool], executionPolicy: .direct)
        default:
            throw Error.unknownModule(function.path)
        }
    }
}
