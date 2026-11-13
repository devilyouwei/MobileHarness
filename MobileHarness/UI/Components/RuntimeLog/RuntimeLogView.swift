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
                                        .accessibilityLabel("收起\(channel.item.title)状态")
                                    }
                                }
                            }
                            if state.observationUnavailable {
                                Text("执行状态暂不可用").font(.caption).foregroundStyle(.orange)
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
                        .accessibilityLabel("执行日志")
                        .accessibilityIdentifier("conversation.actions.history")
                    }
                }
            }
            .sheet(isPresented: $state.showsExecutionHistory) {
                NavigationStack(path: $taskPath) {
                    VStack(spacing: 0) {
                        Picker("记录类型", selection: $state.selectedTab) {
                            ForEach(ExecutionLogTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).padding(.horizontal).padding(.top, 12)
                        HStack {
                            Menu {
                                Button("全部 Agent") { state.selectedSource = "全部" }
                                ForEach(state.sources, id: \.self) { source in
                                    Button(source) { state.selectedSource = source }
                                }
                            } label: {
                                Label(
                                    state.selectedSource == "全部" ? "全部 Agent" : state.selectedSource,
                                    systemImage: "line.3.horizontal.decrease")
                            }
                            Spacer()
                            if state.selectedTab == .action {
                                channelFilter
                                Toggle("内部动作", isOn: $state.showsInternalActions).font(.caption).fixedSize()
                            }
                        }.padding(.horizontal).padding(.vertical, 8)
                        Picker("状态", selection: $state.selectedFilter) {
                            ForEach(ExecutionLogFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
                        if let taskID = state.selectedTaskID,
                            state.selectedTab == .action
                        {
                            HStack {
                                Text("任务：" + taskID).font(.caption)
                                Spacer()
                                Button("查看全部") { state.selectedTaskID = nil }
                            }.padding(.horizontal).padding(.bottom, 8)
                        }
                        List { logRows }
                    }
                    .navigationDestination(for: String.self) { taskDetail($0) }
                    .navigationTitle("执行日志")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { state.showsExecutionHistory = false }
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
                if !active.isEmpty { Section("正在执行与等待") { ForEach(active) { historyRow($0) } } }
                if !finished.isEmpty { Section("最近结果") { ForEach(finished.reversed()) { historyRow($0) } } }
                if state.visibleActions.isEmpty { emptyRow("暂无符合条件的动作") }
                retention(state.evictedCount)
            case .task:
                ForEach(state.visibleTasks.reversed()) { task in
                    NavigationLink(value: task.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.title.isEmpty ? "任务 " + task.id : task.title)
                                .lineLimit(2)
                            Text(
                                task.execution == nil
                                    ? task.requester + " → " + task.executor
                                    : (task.execution == "background" ? "后台任务" : "前台任务") + " · " + task.executor
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
                if state.visibleTasks.isEmpty { emptyRow("暂无符合条件的任务") }
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
                if !issues.isEmpty { Section("运行异常") { ForEach(issues) { issueRow($0) } } }
                if !events.isEmpty {
                    Section("Agent 状态") {
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
                if issues.isEmpty && events.isEmpty { emptyRow("暂无符合条件的 Agent 记录") }
                retention(state.issueEvictions + state.agentEventEvictions)
            case .decision:
                ForEach(state.visibleDecisions) { decision in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(decision.source + " · " + decision.route.rawValue).font(.body.weight(.medium))
                        Text(decision.adoptedResult.rawValue)
                            .foregroundStyle(decision.modelResult == nil ? .orange : .primary)
                        if let result = decision.modelResult, result != decision.adoptedResult {
                            Text("模型结果 · " + result.rawValue).foregroundStyle(.secondary)
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
                                    ? "未发起模型请求"
                                    : decision.requests.joined(separator: "\n\n")
                            )
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("用户输入").font(.caption).foregroundStyle(.secondary)
                                Text(decision.inputText).font(.subheadline).lineLimit(2)
                            }
                        }
                        HStack {
                            Text(decision.time, style: .time)
                            Text("决策耗时 " + decision.duration.formatted(.units(allowed: [.milliseconds])))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("runtimeLog.decision." + decision.id)
                }
                if state.visibleDecisions.isEmpty { emptyRow("暂无符合条件的 Decision 记录") }
                retention(state.decisionEvictions)
            }
        }
        private func emptyRow(_ title: String) -> some View { Text(title).foregroundStyle(.secondary) }
        @ViewBuilder private func retention(_ count: UInt64) -> some View {
            if count > 0 { Text("已移除 \(count) 条较早记录").font(.footnote).foregroundStyle(.secondary) }
        }
        @ViewBuilder private func taskDetail(_ id: String) -> some View {
            if let task = state.tasks.first(where: { $0.id == id }) {
                List {
                    Section("任务") {
                        Text(task.title)
                        Text(
                            task.execution == nil
                                ? task.requester + " → " + task.executor
                                : (task.execution == "background" ? "后台任务" : "前台任务") + " · " + task.executor)
                        Text(task.phase.rawValue)
                        if !task.skills.isEmpty { Text("Skills: " + task.skills.joined(separator: ", ")) }
                        if let parentID = task.parentID {
                            Text("父任务 / 输入：" + parentID).font(.caption).textSelection(.enabled)
                        }
                    }
                    if task.phase == .failed {
                        Section("失败原因") {
                            Text(task.failure ?? "该记录未保留失败原因，请查看关联 Action；可用的 Agent 请求记录见设置中的 Agent 记录。")
                                .textSelection(.enabled)
                        }
                    }
                    Section("时间线") {
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
                            Text("已移除 \(task.evictedEvents) 条较早事件").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("关联记录") {
                        Button("查看 Action") { showTaskActions(id) }

                    }
                }.navigationTitle("任务详情")
            } else {
                Text("该任务记录已超出保留范围")
            }
        }
        private func showTaskActions(_ task: String) {
            taskPath.removeAll()
            state.selectedTaskID = task
            state.selectedTab = .action
            state.selectedFilter = .all
            state.selectedSource = "全部"
            state.selectedChannel = nil
        }

        private var channelFilter: some View {
            Menu {
                Picker("Channel", selection: $state.selectedChannel) {
                    Text("全部 Channel").tag(nil as String?)
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
            .accessibilityLabel("筛选 Channel")
            .accessibilityValue(state.selectedChannel ?? "全部")
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
                if let category = issue.category { Text("类别：" + category).font(.caption) }
                Text(issue.message).font(.subheadline).textSelection(.enabled)
                Text(issue.time, style: .time).font(.caption).foregroundStyle(.secondary)
                if let code = issue.failureCode { Text("错误代码：" + code).font(.caption) }
                if let input = issue.inputID {
                    Text("来源输入：" + input).font(.caption2).textSelection(.enabled)
                }
                if let context = issue.context {
                    DisclosureGroup("关联信息") {
                        Text("所属运行：" + context.workerID)
                        if let callID = context.callID { Text("来源调用：" + callID) }
                        if let sessionID = context.sessionID { Text("会话：" + sessionID) }
                        if let roundID = context.roundID { Text("模型请求/轮次：" + roundID) }
                    }.font(.caption).textSelection(.enabled)
                }
            }
        }

        private func extra(_ channel: ActionChannelSummary) -> String {
            var parts: [String] = []
            if channel.additionalRunning > 0 { parts.append("另有 \(channel.additionalRunning) 项执行中") }
            if channel.queued > 0 { parts.append("还有 \(channel.queued) 项等待") }
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
                    if item.isInternal { Text("内部") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(item.status)
                    if let start = item.execution.startedAt, let end = item.execution.endedAt {
                        Text(end.timeIntervalSince(start).formatted(.number.precision(.fractionLength(2))) + " 秒")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                DisclosureGroup("输入参数与输出结果") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("输入参数").font(.caption.weight(.semibold))
                            if item.parameters.isEmpty {
                                Text("无参数").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(item.parameters.sorted { $0.key < $1.key }, id: \.key) { parameter in
                                    Text(parameter.key + " = " + (parameter.value.isEmpty ? "\"\"" : parameter.value))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("输出结果").font(.caption.weight(.semibold))
                            if let output = item.output {
                                Text(output.isEmpty ? "空字符串" : output)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text(item.isActive ? "等待执行结果" : "未取得返回结果")
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
