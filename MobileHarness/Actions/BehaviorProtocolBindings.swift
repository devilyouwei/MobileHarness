import CallRuntime
import ExecutionRuntime
import FunctionContracts

/// Host-owned registration profiles, grouped by module rather than model aliases or function lists.
public struct BehaviorProtocolBindings {
    enum Error: Swift.Error { case unknownModule(ActionIdentifier) }
    public static func bind(_ function: ActionFunction) throws -> ActionBinding {
        if [
            "Camera.Album.perform", "History.Conversation.readFull", "Speech.Detection.run", "Speech.Listening.prepare",
        ].contains(
            function.path.description)
        {
            return ActionBinding(function: function, protocols: [.tool], executionPolicy: .direct)
        }
        if (function.path.domain == "History" && function.path.module == "Conversation"
            && ["list", "read"].contains(function.path.function))
            || (function.path.domain == "System" && function.path.module == "Provider"
                && function.path.function == "readSettings")
            || (function.path.domain == "System" && function.path.module == "ModelResources"
                && function.path.function == "snapshotResources")
            || (function.path.domain == "System" && function.path.module == "Device"
                && function.path.function == "readStatus")
        {
            return ActionBinding(
                function: function, protocols: [.action, .tool], executionPolicy: .direct,
                directResultPolicy: .returning)
        }
        if (function.path.domain == "Camera" && function.path.module == "Capture")
            || (function.path.domain == "UI" && function.path.module == "Navigation")
            || (function.path.domain == "System" && function.path.module == "Device"
                && ["readEnvironment", "control"].contains(function.path.function))
            || (function.path.domain == "System" && function.path.module == "ModelResources"
                && ["download", "cancel"].contains(function.path.function))
        {
            return ActionBinding(
                function: function, protocols: [.action, .tool], executionPolicy: .direct,
                directResultPolicy: .returning)
        }
        if function.path.domain == "Agent", function.path.module == "Task" {
            return ActionBinding(
                function: function, protocols: [.action], executionPolicy: .direct,
                directResultPolicy: .returning)
        }
        if function.path.domain == "UI", function.path.module == "Expression", function.path.function == "setLoading" {
            return ActionBinding(
                function: function, protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning)
        }
        if function.path.domain == "UI", function.path.module == "Expression",
            function.path.function == "setReplyWaiting"
        {
            return ActionBinding(function: function, protocols: [.action, .tool], executionPolicy: .direct)
        }
        let group = function.path.domain + "." + function.path.module
        if group == "UI.Caption", ["print", "beginReplyTurn"].contains(function.path.function) {
            return ActionBinding(function: function, protocols: [.action, .tool], executionPolicy: .direct)
        }
        switch group {
        case "UI.Expression", "UI.Feedback", "UI.Notice", "UI.Light", "Speech.Playback", "Speech.Listening",
            "NexArm.Motion", "NexArm.Gesture":
            return ActionBinding(function: function)
        case "Speech.Detection", "History.Conversation", "System.Runtime", "System.ModelResources", "System.Provider",
            "UI.ResourcePresentation", "UI.RuntimeDiagnostics", "UI.BluetoothStatus", "System.Device":
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
