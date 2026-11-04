import Foundation

public struct WriterArtifactItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    public let entry: String
    public init(id: String, title: String, state: String, entry: String) {
        self.id = id
        self.title = title
        self.state = state
        self.entry = entry
    }
}
public struct WriterArtifactFile: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let content: String
    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}
public struct WriterArtifactSnapshot: Sendable {
    public let item: WriterArtifactItem
    public let files: [WriterArtifactFile]
    public init(item: WriterArtifactItem, files: [WriterArtifactFile]) {
        self.item = item
        self.files = files
    }
}
@MainActor public protocol WriterArtifactsControlling: AnyObject {
    func read(_ id: String) async throws -> WriterArtifactSnapshot
    func export(_ snapshot: WriterArtifactSnapshot, path: String?, pdf: Bool) async throws -> URL
    func discardExport() async throws
    func preview(_ snapshot: WriterArtifactSnapshot, path: String) async throws -> WriterFilePreview
    func closePreview() async throws
}
public struct WriterTaskItem: Identifiable, Sendable, Codable {
    public let id: String
    public let dialogID: String
    public let goal: String
    public let projectID: String?
    public let runID: String
    public let status: String
    public let failure: String?
    public let updatedAt: Date
    public var startedAt: Date? = nil
    public var requestCount: Int = 0
    public var phase: String? = nil
    public init(
        id: String, dialogID: String, goal: String, projectID: String?, runID: String, status: String, failure: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.dialogID = dialogID
        self.goal = goal
        self.projectID = projectID
        self.runID = runID
        self.status = status
        self.failure = failure
        self.updatedAt = updatedAt
    }
    public var statusTitle: String {
        switch status {
        case "running", "finishing": phase == "waitingUser" ? "进行中 · 等待补充" : phase == "paused" ? "进行中 · 已暂停" : "进行中"
        case "completed", "succeeded": "成功"
        case "cancelled": "已取消"
        case "interrupted": "异常中断"
        default: "异常失败"
        }
    }
}
public struct WriterRequestItem: Identifiable, Sendable {
    public let id: String
    public let position: UInt64
    public let number: Int
    public let runID: String
    public let phase: String
    public let path: String?
    public let attempt: Int
    public let date: Date
    public let state: String
    public init(
        id: String, position: UInt64, number: Int, runID: String, phase: String, path: String?, attempt: Int,
        date: Date, state: String
    ) {
        self.id = id
        self.position = position
        self.number = number
        self.runID = runID
        self.phase = phase
        self.path = path
        self.attempt = attempt
        self.date = date
        self.state = state
    }
    public var icon: String {
        state == "failed"
            ? "exclamationmark.triangle" : attempt > 1 ? "arrow.clockwise" : path == nil ? "brain" : "doc.text"
    }
}
public struct WriterRequestPage: Sendable {
    public let items: [WriterRequestItem]
    public let nextPosition: UInt64?
    public init(items: [WriterRequestItem], nextPosition: UInt64?) {
        self.items = items
        self.nextPosition = nextPosition
    }
}
@MainActor public protocol WriterRecordsControlling: AnyObject {
    func tasks(before: String?) async throws -> [WriterTaskItem]
    func task(_ id: String) async throws -> WriterTaskItem
    func requests(taskID: String, after: UInt64) async throws -> WriterRequestPage
    func message(_ id: String) async throws -> HistoryConversation
    func shareTask(_ id: String) async throws -> String
    func imageData(_ id: String, input: String) async throws -> Data?
}
public struct WriterFilePreview: Sendable {
    public let url: URL
    public let root: URL
    public init(url: URL, root: URL) {
        self.url = url
        self.root = root
    }
}
#if os(iOS)
    import SwiftUI
    import UIKit

    @MainActor public struct WriterRecordsView: View {
        private let controls: any WriterRecordsControlling
        private let artifacts: any WriterArtifactsControlling
        @State private var items: [WriterTaskItem] = []
        @State private var failure: String?
        @State private var more = true
        @State private var loading = false
        @State private var refreshOffset = 0
        public init(controls: any WriterRecordsControlling, artifacts: any WriterArtifactsControlling) {
            self.controls = controls
            self.artifacts = artifacts
        }
        public var body: some View {
            List {
                if let failure { Text(failure).foregroundStyle(.red) }
                ForEach(items) { item in
                    NavigationLink {
                        WriterTaskDetail(seed: item, controls: controls, artifacts: artifacts)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.goal, systemImage: "pencil.and.outline").foregroundStyle(.purple)
                            Text("\(item.id) · \(item.requestCount) 轮").font(.caption.monospaced()).foregroundStyle(
                                .secondary)
                            Text(item.statusTitle).font(.caption).foregroundStyle(
                                .secondary)
                            Text(item.updatedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("writer.task." + item.id)
                }
                if items.isEmpty && !loading && failure == nil { Text("暂无创作任务") }
                if more { Button(loading ? "正在加载…" : "加载更多") { Task { await load(reset: false) } }.disabled(loading) }
            }.navigationTitle("Writer 任务记录").task {
                await load(reset: true)
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(2))
                        try await refreshStates()
                    } catch is CancellationError { return } catch {
                        failure = "状态更新失败：\(error)"
                        return
                    }
                }
            }.refreshable { await load(reset: true) }
        }
        private func refreshStates() async throws {
            guard !loading, !items.isEmpty else { return }
            let targets = Array(items.dropFirst(refreshOffset).prefix(20))
            for item in targets {
                try Task.checkCancellation()
                let updated = try await controls.task(item.id)
                if let index = items.firstIndex(where: { $0.id == updated.id }) { items[index] = updated }
            }
            refreshOffset = items.isEmpty ? 0 : (refreshOffset + 20) % items.count
        }
        private func load(reset: Bool) async {
            guard !loading else { return }
            loading = true
            defer { loading = false }
            do {
                let page = try await controls.tasks(before: reset ? nil : items.last?.id)
                try Task.checkCancellation()
                items = reset ? page : items + page
                more = page.count == 20
                failure = nil
            } catch is CancellationError {} catch { failure = "读取失败：\(error)" }
        }
    }
    @MainActor private struct WriterTaskDetail: View {
        let seed: WriterTaskItem
        let controls: any WriterRecordsControlling
        let artifacts: any WriterArtifactsControlling
        @State private var current: WriterTaskItem?
        @State private var items: [WriterRequestItem] = []
        @State private var next: UInt64?
        @State private var failure: String?
        @State private var sharing: String?
        @State private var showsShare = false
        @State private var sharingBusy = false
        @State private var reading = false
        var body: some View {
            List {
                Section {
                    Label((current ?? seed).goal, systemImage: "pencil.and.outline").foregroundStyle(.purple)
                        .accessibilityIdentifier("writer.task.goal")
                    Text((current ?? seed).id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let date = (current ?? seed).startedAt {
                        LabeledContent("开始时间", value: date.formatted(date: .abbreviated, time: .standard))
                            .accessibilityIdentifier("writer.task.started")
                    }
                    LabeledContent("状态", value: (current ?? seed).statusTitle)
                    LabeledContent("执行轮次", value: String((current ?? seed).requestCount))
                    if let error = (current ?? seed).failure { Text(error).foregroundStyle(.red) }
                    if let project = (current ?? seed).projectID {
                        NavigationLink {
                            WriterArtifactDetail(
                                item: .init(id: project, title: seed.goal, state: "draft", entry: "index.html"),
                                controls: artifacts)
                        } label: {
                            Label("浏览目录文件", systemImage: "folder")
                        }.accessibilityIdentifier("writer.task.files")
                    } else {
                        Label("尚未建立作品目录", systemImage: "folder").foregroundStyle(.secondary)
                    }
                    Button {
                        showsShare = true
                    } label: {
                        Label("导出任务对话记录", systemImage: "square.and.arrow.up")
                    }.disabled(sharingBusy).accessibilityIdentifier("writer.task.export")
                }
                if let failure { Text(failure).foregroundStyle(.red) }
                Section("执行轮次") {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].runID != item.runID {
                            Text("执行 · " + item.runID).font(.caption).foregroundStyle(.secondary)
                        }
                        NavigationLink {
                            WriterRequestDetail(messageID: item.id, controls: controls)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("第\(item.number)轮 · " + item.phase, systemImage: item.icon)
                                if let path = item.path { Text(path).font(.caption.monospaced()) }
                                Text(item.date, format: .dateTime.month().day().hour().minute().second()).font(
                                    .caption2
                                ).foregroundStyle(.secondary)
                                Text(item.state + (item.attempt > 1 ? " · 第\(item.attempt)次尝试" : "")).font(.caption)
                                    .foregroundStyle(item.state == "failed" ? .red : .secondary)
                            }
                        }.accessibilityIdentifier("writer.request." + item.id)
                    }
                    if let next { Button("加载更多") { Task { await load(after: next, reset: false) } }.disabled(reading) }
                }
            }.navigationTitle("任务记录")
                .task {
                    await load(after: 0, reset: true)
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(2))
                            current = try await controls.task(seed.id)
                            if next == nil {
                                let cursor = items.count > 20 ? items[items.count - 21].position : 0
                                await load(after: cursor, reset: false)
                            }
                        } catch is CancellationError { return } catch {
                            failure = "状态更新失败：\(error)"
                            return
                        }
                    }
                }.refreshable { await load(after: 0, reset: true) }
                .sheet(isPresented: $showsShare) {
                    Group { if let sharing { WriterTextShare(text: sharing) } else { ProgressView("正在导出…") } }
                        .task {
                            guard !sharingBusy else { return }
                            sharingBusy = true
                            defer { sharingBusy = false }
                            do { sharing = try await controls.shareTask(seed.id) } catch is CancellationError {} catch {
                                failure = "导出失败：\(error)"
                                showsShare = false
                            }
                        }
                }
        }
        private func load(after: UInt64, reset: Bool) async {
            guard !reading else { return }
            reading = true
            defer { reading = false }
            do {
                current = try await controls.task(seed.id)
                let page = try await controls.requests(taskID: seed.id, after: after)
                try Task.checkCancellation()
                if reset {
                    items = page.items
                } else {
                    for item in page.items {
                        if let index = items.firstIndex(where: { $0.id == item.id }) {
                            items[index] = item
                        } else {
                            items.append(item)
                        }
                    }
                }
                next = page.nextPosition
                failure = nil
            } catch is CancellationError {} catch { failure = "读取失败：\(error)" }
        }
    }
    @MainActor private struct WriterRequestDetail: View {
        let messageID: String
        let controls: any WriterRecordsControlling
        @State private var loaded: HistoryConversation?
        @State private var failure: String?
        private func imageIDs(_ json: String) -> [String] {
            guard let messages = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
                return []
            }
            var seen = Set<String>()
            return Array(
                messages.flatMap { $0["imageReferences"] as? [[String: Any]] ?? [] }.compactMap { $0["id"] as? String }
                    .filter { seen.insert($0).inserted }.prefix(4))
        }
        var body: some View {
            List {
                if let failure { Text(failure).foregroundStyle(.red) }
                ForEach(loaded?.turns ?? []) { input in
                    Section("请求") {
                        Text(input.user).textSelection(.enabled)
                        Text("模型 · " + input.model)
                        Text(input.date, style: .time)
                        if let maximum = input.maximumOutputTokens { Text("最大输出 · \(maximum)") }
                        Text("Temperature · \(input.temperature)")
                        ForEach(input.toolDefinitions ?? [], id: \.self) { definition in
                            DisclosureGroup("工具定义") {
                                Text(definition).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    ForEach(input.generationRounds ?? []) { effect in
                        Section("Writer 运行时收尾") {
                            Text(effect.resultsJSON).font(.system(.caption, design: .monospaced)).textSelection(
                                .enabled)
                        }
                    }
                    ForEach(input.modelRequests ?? []) { request in
                        Section(request.decisionMetadata?.mode ?? "模型请求") {
                            if !request.response.isEmpty { Text(request.response).textSelection(.enabled) }
                            Text(request.state.rawValue)
                            if let reason = request.finishReason { Text("结束原因 · " + reason) }
                            ForEach(imageIDs(request.requestJSON), id: \.self) { id in
                                WriterRequestImage(id: id, input: input.id, controls: controls)
                            }
                            if let usage = request.tokenUsage {
                                Text("Tokens · \(usage.input) 输入 / \(usage.generated) 输出")
                            }
                            if let diagnostic = request.failureDiagnostic {
                                WriterFailureDetail(diagnostic: diagnostic)
                            } else if let error = request.error {
                                Text(error).foregroundStyle(.red)
                            }
                            DisclosureGroup("完整请求") {
                                Text(request.requestJSON).font(.system(.caption, design: .monospaced)).textSelection(
                                    .enabled)
                            }
                        }
                        ForEach(request.toolCalls) { call in
                            Section("Tool · " + call.name) {
                                Text(call.argumentsJSON).font(.system(.caption, design: .monospaced)).textSelection(
                                    .enabled)
                                Text(call.state.rawValue)
                                if let output = call.output { Text(output).textSelection(.enabled) }
                                if let diagnostic = call.failureDiagnostic {
                                    WriterFailureDetail(diagnostic: diagnostic)
                                } else if let error = call.error {
                                    Text(error).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }.navigationTitle("请求详情").task {
                do { loaded = try await controls.message(messageID) } catch { failure = "读取失败：\(error)" }
            }
        }
    }
    @MainActor private struct WriterFailureDetail: View {
        let diagnostic: HistoryFailureDiagnostic
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(diagnostic.message).foregroundStyle(.red).textSelection(.enabled)
                LabeledContent("分类", value: diagnostic.category)
                LabeledContent("阶段", value: diagnostic.stage)
                LabeledContent("错误代码", value: diagnostic.code)
                ForEach(diagnostic.details.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: diagnostic.details[key] ?? "").textSelection(.enabled)
                }
                ForEach(Array(diagnostic.causes.enumerated()), id: \.offset) { index, cause in
                    DisclosureGroup("关联原因 \(index + 1)") {
                        Text(cause.message).foregroundStyle(.red).textSelection(.enabled)
                        LabeledContent("分类", value: cause.category)
                        LabeledContent("阶段", value: cause.stage)
                        LabeledContent("错误代码", value: cause.code)
                        ForEach(cause.details.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: cause.details[key] ?? "").textSelection(.enabled)
                        }
                    }
                }
            }.font(.caption)
        }
    }

    @MainActor private struct WriterRequestImage: View {
        let id: String
        let input: String
        let controls: any WriterRecordsControlling
        @State private var data: Data?
        @State private var image: UIImage?
        @State private var failure: String?
        @State private var expanded = false
        var body: some View {
            Group {
                if let image {
                    Button {
                        expanded = true
                    } label: {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                    }
                } else if let failure {
                    Text(failure).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }.task {
                do {
                    data = try await controls.imageData(id, input: input)
                    if let data { image = await HistoryImageDecoder.decode(data, maximumPixelSize: 320) }
                    if image == nil { failure = "截图不可用" }
                } catch { failure = "截图读取失败：\(error)" }
            }.sheet(isPresented: $expanded) { if let data { HistoryImagePreview(data: data).background(.black) } }
        }
    }
    private struct WriterTextShare: UIViewControllerRepresentable {
        let text: String
        func makeUIViewController(context: Context) -> UIActivityViewController {
            .init(activityItems: [text], applicationActivities: nil)
        }
        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }
    @MainActor private struct WriterArtifactDetail: View {
        let item: WriterArtifactItem
        let controls: any WriterArtifactsControlling
        @State private var snapshot: WriterArtifactSnapshot?
        @State private var failure: String?
        @State private var busy = false
        @State private var operation: Task<Void, Never>?
        @State private var share: WriterShareFile?
        var body: some View {
            List {
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                if let snapshot {
                    Section {
                        Text(snapshot.item.state == "published" ? "已发布作品快照" : "草稿快照 · 可能包含未完成内容")
                            .foregroundStyle(.secondary)
                    }
                    Section("导出当前快照") {
                        Button("导出全部源文件（ZIP）") { export(snapshot, path: nil, pdf: false) }
                        Button("导出作品 PDF") { export(snapshot, path: snapshot.item.entry, pdf: true) }
                        if busy { ProgressView("正在准备导出…") }
                    }.disabled(busy)
                    Section("文件") {
                        ForEach(snapshot.files) { file in
                            NavigationLink(file.path) {
                                WriterFileView(snapshot: snapshot, file: file, controls: controls)
                                    .navigationTitle(file.path)
                            }
                        }
                    }
                }
            }.navigationTitle(item.title)
                .task {
                    do { snapshot = try await controls.read(item.id) } catch { failure = "读取失败：\(error)" }
                }
                .sheet(
                    item: $share,
                    onDismiss: {
                        operation = Task {
                            do { try await controls.discardExport() } catch { failure = "导出清理失败：\(error)" }
                        }
                    }
                ) { WriterActivitySheet(url: $0.url) }
                .onDisappear { operation?.cancel() }
        }
        private func export(_ snapshot: WriterArtifactSnapshot, path: String?, pdf: Bool) {
            guard !busy else { return }
            busy = true
            failure = nil
            operation = Task {
                defer { busy = false }
                do {
                    let url = try await controls.export(snapshot, path: path, pdf: pdf)
                    try Task.checkCancellation()
                    share = WriterShareFile(url: url)
                } catch is CancellationError {} catch { failure = "导出失败：\(error)" }
            }
        }
    }
    @MainActor private struct WriterFileView: View {
        let snapshot: WriterArtifactSnapshot
        let file: WriterArtifactFile
        let controls: any WriterArtifactsControlling
        @State private var preview: WriterFilePreview?
        @State private var page = WebPageContainer()
        @Environment(\.scenePhase) private var scenePhase
        @State private var failure: String?
        @State private var source = false
        @State private var busy = false
        @State private var operation: Task<Void, Never>?
        @State private var share: WriterShareFile?
        var body: some View {
            VStack {
                Toggle("查看源码", isOn: $source).padding(.horizontal)
                if let failure { Text(failure).foregroundStyle(.red) }
                if !source, preview != nil {
                    WebPageView(page: page)
                } else {
                    ScrollView {
                        Text(file.content).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding()
                    }
                }
            }.task {
                do {
                    let prepared = try await controls.preview(snapshot, path: file.path)
                    preview = prepared
                    page.setAvailable(scenePhase == .active)
                    _ = try await page.loadLocal(prepared.url, executesScripts: true, readAccessRoot: prepared.root)
                } catch {
                    failure = "预览失败：\(error)"
                }
            }
            .toolbar {
                Button("导出源文件") { export(pdf: false) }.disabled(busy)
                Button("PDF") { export(pdf: true) }.disabled(busy)
            }
            .sheet(
                item: $share,
                onDismiss: {
                    operation = Task { do { try await controls.discardExport() } catch { failure = "导出清理失败：\(error)" } }
                }
            ) { WriterActivitySheet(url: $0.url) }
            .onChange(of: scenePhase) { _, value in page.setAvailable(value == .active) }
            .onDisappear {
                page.close()
                operation?.cancel()
                page.close()
                Task { do { try await controls.closePreview() } catch { failure = "预览清理失败：\(error)" } }
            }
        }
        private func export(pdf: Bool) {
            guard !busy else { return }
            busy = true
            failure = nil
            operation = Task {
                defer { busy = false }
                do {
                    let url = try await controls.export(snapshot, path: file.path, pdf: pdf)
                    try Task.checkCancellation()
                    share = WriterShareFile(url: url)
                } catch is CancellationError {} catch { failure = "导出失败：\(error)" }
            }
        }
    }
    private struct WriterShareFile: Identifiable {
        let id = UUID()
        let url: URL
    }
    private struct WriterActivitySheet: UIViewControllerRepresentable {
        let url: URL
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: [url], applicationActivities: nil)
        }
        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }
#endif
