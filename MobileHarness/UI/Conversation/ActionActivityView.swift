#if os(iOS)
    import AgentCore
    import SwiftUI

    /// Compact multi-channel status with a read-only execution history sheet.
    @MainActor
    public struct ActionActivityView: View {
        @Bindable private var state: ActionActivityState
        @State private var showingHistory = false
        public init(state: ActionActivityState) { self.state = state }

        public var body: some View {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let channels = state.summaries(at: context.date)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(channels.prefix(3))) { channel in
                        HStack(spacing: 10) {
                            Button {
                                showingHistory = true
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
                                .foregroundStyle(channel.item.isFailure ? Color.orange : Color.white.opacity(0.85))
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
                    if !state.items.isEmpty {
                        Button {
                            showingHistory = true
                        } label: {
                            HStack {
                                Text(channels.count > 3 ? "另有 \(channels.count - 3) 项状态" : "执行记录")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(channels.isEmpty ? 8 : 12)
                .modifier(ActionPanelGlass())
            }
            .accessibilityIdentifier("conversation.actions.status")
            .sheet(isPresented: $showingHistory) {
                NavigationStack {
                    List {
                        let active = state.items.filter(\.isActive)
                        if !active.isEmpty {
                            Section("正在执行与等待") {
                                ForEach(active) { item in historyRow(item) }
                            }
                        }
                        Section("最近结果") {
                            ForEach(state.items.filter { !$0.isActive }.reversed()) { item in historyRow(item) }
                            if state.items.allSatisfy(\.isActive) {
                                Text("还没有已结束的动作").foregroundStyle(.secondary)
                            }
                        }
                        if state.evictedCount > 0 {
                            Text("仅保留最近 100 条结束记录，较早记录已移除。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("执行记录")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingHistory = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
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
                    Text(item.title).font(.body.weight(.medium))
                    Text("\(item.channelTitle) · \(item.status)")
                        .font(.subheadline).foregroundStyle(.secondary)
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
            @State private var robot = BluetoothSettingsState()
            public init() {}
            public var body: some View {
                ConversationView(state: conversation, robot: robot, activity: state, toggleVoice: {})
                    .overlay(alignment: .top) {
                        Text("演示数据 · 不连接设备").font(.caption).padding(12)
                    }
                    .task {
                        conversation.isReady = true
                        conversation.voicePhase = .idle
                        conversation.assistantReply = "好的，我会先跳舞，再向你挥手。"
                        let examples: [(String, String, ActionExecutionRecord.Phase)] = [
                            ("Robot", "跳舞", .running),
                            ("Robot", "挥手", .queued),
                            ("Speech", "朗读回复", .cancelling),
                            ("Robot", "庆祝", .failed),
                        ]
                        state.replace(
                            revision: 1,
                            records: examples.map { channel, title, phase in
                                ActionExecutionRecord(
                                    id: UUID(), path: ActionPath(module: "Fixture", function: "preview"),
                                    displayName: title,
                                    source: .assistant, sessionID: UUID(), inputID: UUID(), channel: channel,
                                    semantics: .finite, phase: phase, endedAt: phase == .failed ? .now : nil,
                                    failureDescription: phase == .failed ? "动作参数无效" : nil)

                            }, evictedCount: 0)
                    }
            }
        }
    #endif
#endif
