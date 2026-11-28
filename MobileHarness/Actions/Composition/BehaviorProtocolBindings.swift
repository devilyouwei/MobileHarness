import CallRuntime
import FunctionContracts

/// Both call routes are available for each installed function. Tool feedback policy is independent of routing.
public struct BehaviorProtocolBindings {
    public static func bind(_ function: ActionFunction) throws -> ActionBinding {
        let binding = ActionBinding(
            function: function, protocols: [.action, .tool], executionPolicy: .direct,
            directResultPolicy: toolResultPolicy(for: function.path))
        try binding.validate()
        return binding
    }

    private static func toolResultPolicy(for path: ActionIdentifier) -> ActionBinding.DirectResultPolicy {
        switch (path.domain, path.module, path.function) {
        case ("History", "Conversation", "readFull"), ("Speech", "Detection", "run"):
            return .completionOnly
        case ("Artifacts", _, _), ("Web", _, _), ("UI", "Island", _),
            ("History", "Conversation", _), ("Speech", "Detection", _),
            ("System", "ModelResources", _), ("System", "Provider", _), ("System", "Device", _),
            ("UI", "ResourcePresentation", _), ("UI", "BluetoothStatus", _),
            ("UI", "Expression", "setLoading"), ("UI", "Navigation", _), ("UI", "Window", _),
            ("Camera", "Capture", _), ("Camera", "Perception", _), ("Camera", "Video", _):
            return .returning
        default:
            return .completionOnly
        }
    }
}
