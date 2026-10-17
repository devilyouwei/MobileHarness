import Foundation

#if os(iOS)
    import SwiftUI

    /// Compact multi-channel status with a read-only execution history sheet.
    @MainActor
    public struct ActionActivityView: View {
        @Bindable private var state: ActionActivityState
        @State private var taskPath: [String] = []
        public init(state: ActionActivityState) {
            self.state = state
        }

        public var body: some View {
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
                                            Image(systemName: channel.item.symbol)
                                                .frame(width: 16)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("\(channel.item.channelTitle) · \(channel.item.title)")
                                                    .font(.caption.weight(.medium))
                                                Text(channel.item.status + extra(channel))
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .foregroundStyle(
                                            channel.item.isFailure ? Color.orange : Color.white.opacity(0.85)
                                        )
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
                        .accessibilityLabel("执行记录")
                        .accessibilityIdentifier("conversation.actions.history")
                    }
                }
            }
            .accessibilityIdentifier("conversation.actions.status")
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
                    .navigationTitle("执行记录")
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
                        Button("查看 Action") { selectRelated(.action, task: id) }

                    }
                }.navigationTitle("任务详情")
            } else {
                Text("该任务记录已超出保留范围")
            }
        }
        private func selectRelated(_ tab: ExecutionLogTab, task: String) {
            taskPath.removeAll()
            state.selectedTaskID = task
            state.selectedTab = tab
            state.selectedFilter = .all
            state.selectedSource = "全部"
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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.symbol)
                    .foregroundStyle(item.isFailure ? Color.orange : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.title).font(.body.weight(.medium))
                        if item.isInternal { Text("内部").font(.caption2).foregroundStyle(.secondary) }
                    }
                    if let start = item.execution.startedAt, let end = item.execution.endedAt {
                        Text(end.timeIntervalSince(start).formatted(.number.precision(.fractionLength(2))) + " 秒")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(
                        "\(item.source.isEmpty ? item.channelTitle : item.source + " · " + item.channelTitle) · \(item.status)"
                    )
                    .font(.subheadline).foregroundStyle(.secondary)
                    if !item.issueDescriptions.isEmpty {
                        DisclosureGroup("查看全部问题") {
                            ForEach(Array(item.issueDescriptions.enumerated()), id: \.offset) { _, description in
                                Text(description).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                Text(item.execution.endedAt ?? item.execution.startedAt ?? item.execution.admittedAt, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
        }
    }
    private struct ActionPanelGlass: ViewModifier {
        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
            } else {
                content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    #if DEBUG
        /// Explicitly synthetic layout fixture: never starts models, audio, camera or device control.
        @MainActor
        public struct ActionActivityVisualPreview: View {
            @State private var state = ActionActivityState()
            @State private var conversation = ConversationState()
            public init() {}
            public var body: some View {
                ConversationView(state: conversation, activity: state, toggleVoice: {})
                    .overlay(alignment: .top) {
                        Text("演示数据 · 不连接设备").font(.caption).padding(12)
                    }
                    .task {
                        conversation.isReady = true
                        conversation.voicePhase = .idle
                        conversation.assistantReply = "好的，我会先跳舞，再向你挥手。"
                        let examples: [(String, String, ActionActivityItem.Execution.Phase)] = [
                            ("Robot", "跳舞", .running),
                            ("Robot", "挥手", .queued),
                            ("Speech", "朗读回复", .cancelling),
                            ("Robot", "庆祝", .failed),
                        ]
                        state.replace(
                            revision: 1,
                            records: examples.map { channel, title, phase in
                                ActionActivityItem(
                                    id: UUID().uuidString, title: title, channel: channel,
                                    status: phase == .failed ? "动作参数无效" : "演示状态",
                                    issueDescriptions: [], symbol: "circle",
                                    execution: .init(
                                        phase: phase, admittedAt: .now,
                                        startedAt: nil, endedAt: phase == .failed ? .now : nil))

                            }, evictedCount: 0)
                    }
            }
        }
    #endif
#endif
