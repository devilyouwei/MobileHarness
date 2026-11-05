import Foundation
import FunctionContracts

public enum WindowActions {
    @Action(
        domain: "UI", module: "Window", title: "focus",
        doc:
            "Focus window; await presentation and required lifecycle.",
        parameters: [
            .init(
                "windowID", type: .string, required: true,
                description: "Actual ID from ui.windows/openCamera.")
        ], timeout: .seconds(60))
    public static func focus(invocation: any FunctionInput, using windows: any WindowControlCapability) async throws
        -> String
    {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["windowID"])
        let raw = try args.requiredString("windowID", maximumUTF8Bytes: 36)
        let id = raw
        guard raw.hasPrefix("window_"), let number = UInt64(raw.dropFirst(7)), number > 0, raw == "window_\(number)"
        else { throw ActionArguments.ValidationError.invalidValue("windowID") }
        try Task.checkCancellation()
        try await windows.performWindow(.focus, id: id, x: nil, y: nil, invocation: invocation)
        return "presented"
    }
    @Action(
        domain: "UI", module: "Window", title: "minimize",
        doc:
            "Minimize window; await presentation and required lifecycle.",
        parameters: [
            .init(
                "windowID", type: .string, required: true,
                description: "Actual ID from ui.windows/openCamera.")
        ], timeout: .seconds(60))
    public static func minimize(invocation: any FunctionInput, using windows: any WindowControlCapability) async throws
        -> String
    {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["windowID"])
        let raw = try args.requiredString("windowID", maximumUTF8Bytes: 36)
        let id = raw
        guard raw.hasPrefix("window_"), let number = UInt64(raw.dropFirst(7)), number > 0, raw == "window_\(number)"
        else { throw ActionArguments.ValidationError.invalidValue("windowID") }
        try Task.checkCancellation()
        try await windows.performWindow(.minimize, id: id, x: nil, y: nil, invocation: invocation)
        return "presented"
    }
    @Action(
        domain: "UI", module: "Window", title: "maximize",
        doc:
            "Maximize window; await presentation and required lifecycle.",
        parameters: [
            .init(
                "windowID", type: .string, required: true,
                description: "Actual ID from ui.windows/openCamera.")
        ], timeout: .seconds(60))
    public static func maximize(invocation: any FunctionInput, using windows: any WindowControlCapability) async throws
        -> String
    {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["windowID"])
        let raw = try args.requiredString("windowID", maximumUTF8Bytes: 36)
        let id = raw
        guard raw.hasPrefix("window_"), let number = UInt64(raw.dropFirst(7)), number > 0, raw == "window_\(number)"
        else { throw ActionArguments.ValidationError.invalidValue("windowID") }
        try Task.checkCancellation()
        try await windows.performWindow(.maximize, id: id, x: nil, y: nil, invocation: invocation)
        return "presented"
    }
    @Action(
        domain: "UI", module: "Window", title: "restore",
        doc:
            "Restore window; await presentation and required lifecycle.",
        parameters: [
            .init(
                "windowID", type: .string, required: true,
                description: "Actual ID from ui.windows/openCamera.")
        ], timeout: .seconds(60))
    public static func restore(invocation: any FunctionInput, using windows: any WindowControlCapability) async throws
        -> String
    {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["windowID"])
        let raw = try args.requiredString("windowID", maximumUTF8Bytes: 36)
        let id = raw
        guard raw.hasPrefix("window_"), let number = UInt64(raw.dropFirst(7)), number > 0, raw == "window_\(number)"
        else { throw ActionArguments.ValidationError.invalidValue("windowID") }
        try Task.checkCancellation()
        try await windows.performWindow(.restore, id: id, x: nil, y: nil, invocation: invocation)
        return "presented"
    }
    @Action(
        domain: "UI", module: "Window", title: "move",
        doc:
            "Move window; await presentation and required lifecycle.",
        parameters: [
            .init(
                "windowID", type: .string, required: true,
                description: "Actual ID from ui.windows/openCamera."),
            .init("x", type: .number, required: true, description: "Horizontal safe-area position, 0...1."),
            .init("y", type: .number, required: true, description: "Vertical safe-area position, 0...1."),
        ], timeout: .seconds(60))
    public static func move(invocation: any FunctionInput, using windows: any WindowControlCapability) async throws
        -> String
    {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["windowID", "x", "y"])
        let raw = try args.requiredString("windowID", maximumUTF8Bytes: 36)
        let id = raw
        guard raw.hasPrefix("window_"), let number = UInt64(raw.dropFirst(7)), number > 0, raw == "window_\(number)"
        else { throw ActionArguments.ValidationError.invalidValue("windowID") }
        let x = try args.requiredFiniteDouble("x", range: 0...1)
        let y = try args.requiredFiniteDouble("y", range: 0...1)
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw ActionArguments.ValidationError.invalidValue("position")
        }
        try Task.checkCancellation()
        try await windows.performWindow(.move, id: id, x: x, y: y, invocation: invocation)
        return "presented"
    }
    @Action(
        domain: "UI", module: "Window", title: "close",
        doc:
            "Close window; await presentation and required lifecycle.",
        parameters: [
            .init(
                "windowID", type: .string, required: true,
                description: "Actual ID from ui.windows/openCamera.")
        ], timeout: .seconds(60))
    public static func close(invocation: any FunctionInput, using windows: any WindowControlCapability) async throws
        -> String
    {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["windowID"])
        let raw = try args.requiredString("windowID", maximumUTF8Bytes: 36)
        let id = raw
        guard raw.hasPrefix("window_"), let number = UInt64(raw.dropFirst(7)), number > 0, raw == "window_\(number)"
        else { throw ActionArguments.ValidationError.invalidValue("windowID") }
        try Task.checkCancellation()
        try await windows.performWindow(.close, id: id, x: nil, y: nil, invocation: invocation)
        return "presented"
    }
}
