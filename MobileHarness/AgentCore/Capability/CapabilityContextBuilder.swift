/// Builds system-prompt guidance for visible Function Token Actions only.
/// Native Tool Call metadata belongs to a separate provider protocol, never this text context.
public enum CapabilityContextBuilder {
    public static func build(_ registry: CapabilityRegistry) -> String {
        var lines = [
            "输出协议：自然文本自动映射为语音、字幕等已配置动作。显式 Action 只能使用下列清单中的自闭 XML 标签，参数值必须加引号。",
            "同一任务内，同一 Channel 的动作按顺序执行，前一个完成后才开始下一个；不同 Channel 可以并行，但同一设备模块不能同时执行多个动作。输出先后不代表跨轨完成先后。",
            "未指定 Channel 时使用各 Action 的默认轨道。使用 <channel.名称>...</channel.名称> 改变内部文本和动作的轨道；闭合只恢复外层或默认轨道，不等待、不停止动作。Channel 名称没有特殊主轨语义。",
            "<wait>...</wait> 表示前后等待：先等所在父组此前的动作全部完成，再执行组内动作；组内仍同轨串行、异轨并行，全部完成后才放行父组后续动作。等待只影响当前任务。",
            "需要先 A 后 B：写成 <wait>A</wait><wait>B</wait>；需要一组动作同时进行再继续：将它们放入同一个 wait，并使用不同轨道。A、B 是说明用的占位符，实际输出应是已注册动作或要说的话。",
            "wait 可以嵌套，内层只等待父组此前的工作。wait 不接受属性或自闭写法；必须使用 </wait> 结束。所有标签正确嵌套，不要交叉闭合。最多 32 个 wait，wait 与 Channel 合计嵌套最多 8 层。",
            "动作完成由其实现决定，例如语音要等播放结束；标签闭合、请求生成或入队不代表实际动作完成，不要声称未经确认的操作已完成。",
            "文本中的 < 和 & 必须写为 &lt; 和 &amp;，属性里的双引号使用 &quot;。不输出根标签、注释、DOCTYPE、CDATA、成对 Action、parallel/serial 标签或 sync 属性。",
            "可用 Channel：\(registry.channels.sorted().joined(separator: ", "))。以下为已注册的可见 Action：",
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
