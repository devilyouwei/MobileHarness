import FunctionContracts

/// Domain namespace; callable implementations live in cohesive module files.
public enum NexArmActions {
    static func motionValue(
        _ key: String, _ invocation: any FunctionInput, default fallback: Int, range: ClosedRange<Int>
    ) throws -> Int {
        guard invocation.call.parameters[key] != nil else { return fallback }
        return try ActionArguments(invocation.call.parameters).requiredInt(key, range: range)
    }
}
