/// Builds system-prompt guidance for visible Function Token Actions only.
/// Native Tool Call metadata belongs to a separate provider protocol, never this text context.
public enum CapabilityContextBuilder {
    public static func build(_ registry: CapabilityRegistry) -> String {
        var lines = [
            "动作协议：自然文本会按本 Agent 的文本动作映射执行。显式动作只能使用下列可见 Action 的自闭 XML 标签。",
            "可用 channel：\(registry.channels.sorted().joined(separator: ", "))。使用 <channel.main>...</channel.main> 指定作用域；闭合后恢复外层或动作默认 channel。",
            "文本中的 < 和 & 必须写为 &lt; 和 &amp;。不要输出注释、DOCTYPE、CDATA 或非自闭动作。",
        ]
        for action in registry.actions where !action.hidden {
            lines.append(
                "Action \(action.alias)：必填字符串参数 \(action.requiredParameters.sorted())；可选 \(action.optionalParameters.sorted())；默认 channel=\(action.defaultChannel)"
            )
            if let documentation = action.documentation { lines += describe(documentation) }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ documentation: CapabilityDocumentation) -> [String] {
        [documentation.doc]
            + documentation.parameters.map {
                "Parameter \($0.name): \($0.valueType.rawValue). \($0.description) \($0.constraints)"
            }
            + documentation.examples.map { "Example: \($0)" }
    }
}
