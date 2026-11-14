import Foundation

#if os(iOS)
    import SwiftUI

    /// Compact multi-channel status with a read-only execution history sheet.
    @MainActor
    public struct RuntimeLogView: View {
        @Bindable private var state: RuntimeLogState
        @State private var taskPath: [String] = []
        public init(state: RuntimeLogState) {
            self.state = state
        }

        public var body: some View {
            if state.hasRecords || state.observationUnavailable {
                panel
            }
        }

        private var panel: some View {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let channels = state.summaries(at: context.date)
                VStack(alignment: .trailing, spacing: 12) {
                    if !channels.isEmpty || state.observationUnavailable {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(channels.prefix(3))) { channel in
                                HStack(spacing: 10) {
                                    Button {
                                        state.showsExecutionHistory = true
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            actionStatusIcon(channel.item.execution.phase)
                                                .frame(width: 16)
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(alignment: .top, spacing: 6) {
                                                    channelLabel(channel.id)
                                                    Text(channel.item.title)
                                                        .font(.system(.caption, design: .monospaced).weight(.medium))
                                                }
                                                Text(channel.item.status + extra(channel))
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .foregroundStyle(.primary)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if !channel.item.isActive {
                                        Button {
                                            state.dismiss(channel.item.id)
                                        } label: {
                                            Image(systemName: "xmark").font(.caption).padding(8)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Hide \(channel.item.title) status")
                                    }
                                }
                            }
                            if state.observationUnavailable {
                                Text("Execution status temporarily unavailable").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: 440)
                        .modifier(ActionPanelGlass())
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    if state.hasRecords {
                        Button {
                            state.showsExecutionHistory = true
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 48, height: 48)
                        }
                        .buttonStyle(.plain)
                        .modifier(ActionPanelGlass())
                        .accessibilityLabel("Execution Log")
                        .accessibilityIdentifier("conversation.actions.history")
                    }
                }
            }
            .sheet(isPresented: $state.showsExecutionHistory) {
                NavigationStack(path: $taskPath) {
                    VStack(spacing: 0) {
                        Picker("Record type", selection: $state.selectedTab) {
                            ForEach(ExecutionLogTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).padding(.horizontal).padding(.top, 12)
                        HStack {
                            Menu {
                                Button("All Agents") { state.selectedSource = "All" }
                                ForEach(state.sources, id: \.self) { source in
                                    Button(source) { state.selectedSource = source }
                                }
                            } label: {
                                Label(
                                    state.selectedSource == "All" ? "All Agents" : state.selectedSource,
                                    systemImage: "line.3.horizontal.decrease")
                            }
                            Spacer()
                            if state.selectedTab == .action {
                                channelFilter
                                Toggle("Internal actions", isOn: $state.showsInternalActions).font(.caption).fixedSize()
                            }
                        }.padding(.horizontal).padding(.vertical, 8)
                        Picker("Status", selection: $state.selectedFilter) {
                            ForEach(ExecutionLogFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
                        if let taskID = state.selectedTaskID,
                            state.selectedTab == .action
                        {
                            HStack {
                                Text("Task: " + taskID).font(.caption)
                                Spacer()
                                Button("Show all") { state.selectedTaskID = nil }
                            }.padding(.horizontal).padding(.bottom, 8)
                        }
                        List { logRows }
                    }
                    .navigationDestination(for: String.self) { taskDetail($0) }
                    .navigationTitle("Execution Log")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { state.showsExecutionHistory = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }

        @ViewBuilder private var logRows: some View {
            switch state.selectedTab {
            case .action:
                let active = state.visibleActions.filter(\.isActive)
                let finished = state.visibleActions.filter { !$0.isActive }
                if !active.isEmpty { Section("Running and queued") { ForEach(active) { historyRow($0) } } }
                if !finished.isEmpty { Section("Recent results") { ForEach(finished.reversed()) { historyRow($0) } } }
                if state.visibleActions.isEmpty { emptyRow("No matching actions") }
                retention(state.evictedCount)
            case .task:
                ForEach(state.visibleTasks.reversed()) { task in
                    NavigationLink(value: task.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.title.isEmpty ? "Task " + task.id : task.title)
                                .lineLimit(2)
                            Text(
                                task.execution == nil
                                    ? task.requester + " → " + task.executor
                                    : (task.execution == "background" ? "Background task" : "Foreground task") + " · "
                                        + task.executor
                            ).font(.caption).foregroundStyle(.secondary)
                            Text(task.phase.rawValue).font(.subheadline).foregroundStyle(
                                task.phase == .failed ? .orange : .secondary)
                            if !task.skills.isEmpty {
                                Text("Skills: " + task.skills.joined(separator: ", ")).font(.caption).foregroundStyle(
                                    .secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if state.visibleTasks.isEmpty { emptyRow("No matching tasks") }
                retention(state.taskEvictions)
            case .agent:
                let issues = state.runtimeIssues.filter {
                    state.matchesSource([$0.source])
                        && state.matchesStatus(active: false, success: false, failure: true)
                }
                let events = state.agentEvents.filter {
                    state.matchesSource([$0.source])
                        && state.matchesStatus(active: false, success: !$0.isFailure, failure: $0.isFailure)
                }
                if !issues.isEmpty { Section("Runtime issues") { ForEach(issues) { issueRow($0) } } }
                if !events.isEmpty {
                    Section("Agent status") {
                        ForEach(events.reversed()) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.source).font(.body.weight(.medium))
                                Text(event.status).font(.subheadline).foregroundStyle(
                                    event.isFailure ? .orange : .secondary)
                                Text(event.time, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if issues.isEmpty && events.isEmpty { emptyRow("No matching Agent records") }
                retention(state.issueEvictions + state.agentEventEvictions)
            case .decision:
                ForEach(state.visibleDecisions) { decision in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(decision.source + " · " + decision.route.rawValue).font(.body.weight(.medium))
                        Text(decision.adoptedResult.rawValue)
                            .foregroundStyle(decision.modelResult == nil ? .orange : .primary)
                        if let result = decision.modelResult, result != decision.adoptedResult {
                            Text("Model result · " + result.rawValue).foregroundStyle(.secondary)
                        }
                        if let reason = decision.reason {
                            Text(reason).foregroundStyle(.secondary)
                        }
                        if let localFallback = decision.localFallback {
                            Text(localFallback).foregroundStyle(.secondary)
                        }
                        DisclosureGroup {
                            Text(
                                decision.requests.isEmpty
                                    ? "No model request was sent"
                                    : decision.requests.joined(separator: "\n\n")
                            )
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("User input").font(.caption).foregroundStyle(.secondary)
                                Text(decision.inputText).font(.subheadline).lineLimit(2)
                            }
                        }
                        HStack {
                            Text(decision.time, style: .time)
                            Text("Decision duration " + decision.duration.formatted(.units(allowed: [.milliseconds])))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("runtimeLog.decision." + decision.id)
                }
                if state.visibleDecisions.isEmpty { emptyRow("No matching Decision records") }
                retention(state.decisionEvictions)
            }
        }
        private func emptyRow(_ title: String) -> some View { Text(title).foregroundStyle(.secondary) }
        @ViewBuilder private func retention(_ count: UInt64) -> some View {
            if count > 0 { Text("Removed \(count) older records").font(.footnote).foregroundStyle(.secondary) }
        }
        @ViewBuilder private func taskDetail(_ id: String) -> some View {
            if let task = state.tasks.first(where: { $0.id == id }) {
                List {
                    Section("Task") {
                        Text(task.title)
                        Text(
                            task.execution == nil
                                ? task.requester + " → " + task.executor
                                : (task.execution == "background" ? "Background task" : "Foreground task") + " · "
                                    + task.executor)
                        Text(task.phase.rawValue)
                        if !task.skills.isEmpty { Text("Skills: " + task.skills.joined(separator: ", ")) }
                        if let parentID = task.parentID {
                            Text("Parent task / input: " + parentID).font(.caption).textSelection(.enabled)
                        }
                    }
                    if task.phase == .failed {
                        Section("Failure reason") {
                            Text(
                                task.failure
                                    ?? "This record has no retained cause. Check related Actions and the Agent records in Settings."
                            )
                            .textSelection(.enabled)
                        }
                    }
                    Section("Timeline") {
                        ForEach(task.events) { event in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.blue).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(event.title)
                                    if !event.detail.isEmpty {
                                        Text(event.detail).font(.subheadline).textSelection(.enabled)
                                    }
                                    Text(event.time, style: .time).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if task.evictedEvents > 0 {
                            Text("Removed \(task.evictedEvents) older events").font(.caption).foregroundStyle(
                                .secondary)
                        }
                    }
                    Section("Related records") {
                        Button("View Actions") { showTaskActions(id) }

                    }
                }.navigationTitle("Task details")
            } else {
                Text("This task record is no longer retained")
            }
        }
        private func showTaskActions(_ task: String) {
            taskPath.removeAll()
            state.selectedTaskID = task
            state.selectedTab = .action
            state.selectedFilter = .all
            state.selectedSource = "All"
            state.selectedChannel = nil
        }

        private var channelFilter: some View {
            Menu {
                Picker("Channel", selection: $state.selectedChannel) {
                    Text("All Channels").tag(nil as String?)
                    ForEach(state.actionChannels, id: \.self) { channel in
                        Text(channel).tag(Optional(channel))
                    }
                }
            } label: {
                if let selected = state.selectedChannel {
                    channelLabel(selected)
                } else {
                    Label("Channel", systemImage: "line.3.horizontal.decrease")
                }
            }
            .accessibilityLabel("Filter by Channel")
            .accessibilityValue(state.selectedChannel ?? "All")
            .accessibilityIdentifier("runtimeLog.action.channelFilter")
        }

        private func channelLabel(_ channel: String) -> some View {
            let color = channelColor(channel)
            return Label {
                Text(channel)
            } icon: {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            .lineLimit(1)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.24), in: Capsule())
        }

        private func channelColor(_ channel: String) -> Color {
            switch channel {
            case "Camera": return .cyan
            case "Control": return .purple
            case "Display": return .indigo
            case "Listening": return .teal
            case "ListeningControl": return .mint
            case "Query": return .blue
            case "Robot": return .orange
            case "Speech": return .pink
            case "System": return .brown
            default:
                let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo, .brown, .cyan]
                let hash = channel.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
                return palette[Int(hash % UInt32(palette.count))]
            }
        }

        private func actionStatusIcon(_ phase: ActionActivityItem.Execution.Phase) -> some View {
            let appearance: (symbol: String, color: Color) =
                switch phase {
                case .queued: ("clock", .secondary)
                case .running: ("arrow.triangle.2.circlepath", .blue)
                case .cancelling: ("hourglass", .orange)
                case .succeeded: ("checkmark.circle", .green)
                case .failed: ("exclamationmark.circle", .red)
                case .cancelled: ("minus.circle", .secondary)
                }
            return Image(systemName: appearance.symbol)
                .foregroundStyle(appearance.color)
                .accessibilityHidden(true)
        }

        private func issueRow(_ issue: ExecutionIssue) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.title).font(.body.weight(.medium))
                Text(issue.source).font(.caption).foregroundStyle(.secondary)
                if let category = issue.category { Text("Category: " + category).font(.caption) }
                Text(issue.message).font(.subheadline).textSelection(.enabled)
                Text(issue.time, style: .time).font(.caption).foregroundStyle(.secondary)
                if let code = issue.failureCode { Text("Error code: " + code).font(.caption) }
                if let input = issue.inputID {
                    Text("Source input: " + input).font(.caption2).textSelection(.enabled)
                }
                if let context = issue.context {
                    DisclosureGroup("Related context") {
                        Text("Worker: " + context.workerID)
                        if let callID = context.callID { Text("Source call: " + callID) }
                        if let sessionID = context.sessionID { Text("Session: " + sessionID) }
                        if let roundID = context.roundID { Text("Model request / round: " + roundID) }
                    }.font(.caption).textSelection(.enabled)
                }
            }
        }

        private func extra(_ channel: ActionChannelSummary) -> String {
            var parts: [String] = []
            if channel.additionalRunning > 0 { parts.append("\(channel.additionalRunning) more running") }
            if channel.queued > 0 { parts.append("\(channel.queued) more queued") }
            return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
        }

        private func historyRow(_ item: ActionActivityItem) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    actionStatusIcon(item.execution.phase)
                        .frame(width: 20)
                    Text(item.title)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Text(item.execution.endedAt ?? item.execution.startedAt ?? item.execution.admittedAt, style: .time)
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    channelLabel(item.channel)
                    if !item.source.isEmpty { Text(item.source) }
                    if item.isInternal { Text("Internal") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(item.status)
                    if let start = item.execution.startedAt, let end = item.execution.endedAt {
                        Text(end.timeIntervalSince(start).formatted(.number.precision(.fractionLength(2))) + " sec")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                DisclosureGroup("Inputs and outputs") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Input parameters").font(.caption.weight(.semibold))
                            if item.parameters.isEmpty {
                                Text("No parameters").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(item.parameters.sorted { $0.key < $1.key }, id: \.key) { parameter in
                                    Text(parameter.key + " = " + (parameter.value.isEmpty ? "\"\"" : parameter.value))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Output").font(.caption.weight(.semibold))
                            if let output = item.output {
                                Text(output.isEmpty ? "Empty string" : output)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text(item.isActive ? "Waiting for result" : "No result received")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(item.issueDescriptions.enumerated()), id: \.offset) { _, description in
                                Text(description).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
                .font(.subheadline)
                .accessibilityIdentifier("runtimeLog.action.details." + item.id)
            }
            .padding(.vertical, 4)
        }
    }
    private struct ActionPanelGlass: ViewModifier {
        @ViewBuilder
        func body(content: Content) -> some View {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
        }
    }

#endif
