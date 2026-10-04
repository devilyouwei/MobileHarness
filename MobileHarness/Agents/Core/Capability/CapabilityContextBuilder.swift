/// Builds English scheduling guidance and registered, visible Action metadata.
/// Internal permissions and native Tool metadata never enter the model-facing catalog.
public enum CapabilityContextBuilder {
    public static func build(_ registry: CapabilityRegistry) throws -> String {
        var lines = [
            "OUTPUT FORMAT",
            "Write natural text and registered self-closing Action tags. Use only aliases from the callable Action list below; quote all attribute values. Do not invent Actions, parameters or Channels.",
            "SCHEDULING: CHANNEL, MODULE, WAIT",
            "A Channel is an ordering queue, not a device module. Within this task, Actions on the same Channel execute in output order, each waiting for the previous Action to finish. Different Channels may run concurrently; output order alone does not order their completion.",
            "A module is an execution resource. Only one Action per module can run at a time across all tasks, even on different Channels. Changing a Channel never changes an Action's module. Different modules on the same Channel still execute serially. Parallel execution is allowed, never guaranteed.",
            "Each Action uses its listed default Channel unless enclosed in <channel.NAME>...</channel.NAME>, using an available Channel name. This overrides the Channel of enclosed text and Actions. Closing the scope restores the outer scope or each Action's own default. Channel tags neither wait nor stop Actions; no name has special main-channel behavior.",
            "Use <wait>...</wait> for execution dependencies. Before its contents can start, all earlier work in its parent group must finish. Inside the group, normal Channel ordering and module exclusion still apply. Later work in the parent cannot start until the group is closed AND all its Actions and nested groups have finished.",
            "The whole response has an implicit root group. Nested waits apply the same rule within their own parent only; they never wait on themselves, ancestors or unrelated tasks. A group may start received Actions before its closing tag arrives. <wait></wait> is a valid empty synchronization point. Wait does not change Channels.",
            "Patterns (A, B, C and D are placeholders for actual Actions or natural text, not tags to output): <wait>A B</wait><wait>C D</wait> completes the first group before starting the second. <wait>A <wait>B C</wait> D</wait> completes A before B/C, and completes B/C before D. B/C may overlap only on different Channels and different modules.",
            "SYNTAX RULES",
            "Channel and wait tags must be paired, properly nested and attribute-free. Never cross closing tags or write <wait/> or a self-closing Channel. Action tags must be self-closing. At most 32 wait groups, 8 combined Channel/wait nesting levels and 120 generated Actions are allowed.",
            "Escape literal < and & in text as &lt; and &amp;; use &quot; for quotes inside double-quoted attributes. Do not output a document root, comments, DOCTYPE, CDATA, paired Action tags, parallel/serial tags or sync attributes.",
            "AVAILABLE CHANNELS: \(registry.channels.sorted().joined(separator: ", "))",
        ]
        lines.append(
            "Natural-text interpretation is supplied by the calling Agent; text alone implies no execution effect.")
        lines.append("ACTIONS BY DEFAULT CHANNEL (use the Action alias as the XML tag):")
        for channel in registry.channels.sorted() {
            lines.append(
                "Channel \(channel)")
            for action in registry.actions where action.defaultChannel == channel {
                lines.append(
                    "Action \(action.alias): module=\(action.path.module); default Channel=\(action.defaultChannel); required string parameters=\(action.requiredParameters.sorted()); optional=\(action.optionalParameters.sorted())."
                )
                if let documentation = action.documentation { lines += describe(documentation) }
            }
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
