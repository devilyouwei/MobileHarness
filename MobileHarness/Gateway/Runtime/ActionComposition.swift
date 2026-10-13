import Foundation
import FunctionContracts

/// Validated finite tree; children inherit the root's resource fence, never reacquire it.
public struct ActionComposition: Sendable {
    public indirect enum Node: Sendable {
        case action(
            String, Set<ActionResource>, maximumResults: Int = 1, budget: ActionExecutionBudget? = nil,
            @Sendable () async throws -> ActionCompletion)
        /// Resolve the canonical child contract before any effects; retain inherited resource authority.
        public static func action(
            function: ActionFunction, invocation: any FunctionInput, maximumResults: Int = 1
        ) throws -> Node {
            guard function.path == invocation.call.actionPath else {
                throw ActionExecutionError.invalidDefinition(function.path)
            }
            return try .action(
                function.path.function, function.requiredResources(for: invocation.call),
                maximumResults: maximumResults, budget: function.executionBudget(for: invocation.call)
            ) {
                do { return try await FunctionExecutor.invoke(invocation, definition: function) } catch {
                    if let report = await invocation.results.snapshot() {
                        return .report(report.recordingFailure(error))
                    }
                    throw error
                }
            }
        }
        case sequence([Node])
        case parallel([Node])
        case repeated(Int, Node)
        case delay(Duration)
    }
    public enum ConfigurationError: Error { case limit, overlappingResources, invalidDelay }
    private let root: Node
    public let resources: Set<ActionResource>
    public init(_ root: Node) throws {
        let validated = try Self.validate(root, depth: 0)
        guard validated.count <= 256, validated.resources.count <= 8 else { throw ConfigurationError.limit }
        _ = try Self.budget(root)
        self.root = root
        resources = validated.resources
    }
    private static func validate(_ node: Node, depth: Int) throws -> (count: Int, resources: Set<ActionResource>) {
        guard depth <= 8 else { throw ConfigurationError.limit }
        switch node {
        case .action(let name, let resources, let budget, _, _):
            guard (1...256).contains(budget), !name.isEmpty, name.utf8.count <= 32 else {
                throw ConfigurationError.limit
            }
            return (budget + 1, resources)
        case .delay(let duration):
            guard duration >= .zero, duration <= .seconds(30) else { throw ConfigurationError.invalidDelay }
            return (1, [])
        case .repeated(let count, let child):
            guard (1...32).contains(count) else { throw ConfigurationError.limit }
            let v = try validate(child, depth: depth + 1)
            guard v.count * count <= 256 else { throw ConfigurationError.limit }
            return (v.count * count, v.resources)
        case .sequence(let children), .parallel(let children):
            guard children.count <= 256 else { throw ConfigurationError.limit }
            var count = 0
            var resources: Set<ActionResource> = []
            for child in children {
                let v = try validate(child, depth: depth + 1)
                if case .parallel = node, !resources.isDisjoint(with: v.resources) {
                    throw ConfigurationError.overlappingResources
                }
                count += v.count
                resources.formUnion(v.resources)
                guard count <= 256 else { throw ConfigurationError.limit }
            }
            return (count, resources)
        }
    }
    /// Every leaf has a budget. Empty compositions receive a minimal positive deadline.
    public var executionBudget: ActionExecutionBudget { get throws { try Self.budget(root) } }
    private static func budget(_ node: Node) throws -> ActionExecutionBudget {
        switch node {
        case .action(_, _, _, let budget, _): return budget ?? .default
        case .delay(let duration):
            return try ActionExecutionBudget(expected: duration, timeout: duration + .milliseconds(100))
        case .repeated(let count, let child):
            return try .sequence(Array(repeating: budget(child), count: count))
        case .sequence(let nodes): return try .sequence(nodes.map { try budget($0) })
        case .parallel(let nodes): return try .parallel(nodes.map { try budget($0) })
        }
    }
    /// Pure request-to-tree builder: no effects during budget/resource resolution.
    /// Use the same builder for metadata and execution so the outer budget follows the children.
    public static func function(
        path: ActionIdentifier, declaration: ActionDeclaration? = nil, displayName: String,
        completion: String = "All composed children and cleanup joined.",
        composing make: @escaping @Sendable (FunctionRequest) throws -> ActionComposition
    ) -> ActionFunction {
        ActionFunction(
            path: path, declaration: declaration, displayName: displayName, kind: .finite,
            completion: completion,
            resolvingResources: { try make($0).resources },
            dynamicTimeout: { try make($0).executionBudget },
            completing: { .report(try await make($0.call).run()) })
    }
    private static func flatten(_ report: ActionReport, path: String) -> [ActionReport.Entry] {
        var entries = report.entries.map {
            ActionReport.Entry(
                path: "\(path).\($0.path)",
                status: report.executionFailure == .timedOut && $0.code == .cancelled ? .failed : $0.status,
                code: report.executionFailure == .timedOut && $0.code == .cancelled ? .timedOut : $0.code,
                details: $0.details)
        }
        if let code = report.executionFailure {
            entries.append(
                .init(
                    path: "\(path).execution", status: .failed, code: code,
                    details: failureDetails(report.failureDescription)))
        }
        return entries
    }
    private static func failureDetails(_ description: String?) -> [String: String] {
        guard var description else { return [:] }
        while description.utf8.count > 512 { description.removeLast() }
        return ["failureDescription": description]
    }
    private actor CompletionStore {
        var completion: ActionCompletion?
        func record(_ value: ActionCompletion) { completion = value }
    }
    public func run() async throws -> ActionReport {
        if Task.isCancelled {
            return try ActionReport(entries: await Self.run(root, path: "root")).withExecutionFailure(.cancelled)
        }
        let reports = ActionReportStore()
        do {
            let completion = try await ActionDeadline.run(
                budget: executionBudget, report: { await reports.snapshot() },
                body: {
                    let report = try ActionReport(entries: await Self.run(root, path: "root"))
                    try await reports.record(report)
                    return .report(report)
                })
            guard case .report(let report) = completion else { throw ActionExecutionError.invalidCompletion }
            return report
        } catch is CancellationError {
            if let report = await reports.snapshot() { return report.withExecutionFailure(.cancelled) }
            return try ActionReport(entries: await Self.run(root, path: "root"))
                .withExecutionFailure(.cancelled)
        }
    }
    private static func run(_ node: Node, path: String) async -> [ActionReport.Entry] {
        switch node {
        case .sequence(let nodes):
            var results: [ActionReport.Entry] = []
            for (index, child) in nodes.enumerated() {
                results += await run(child, path: "\(path).\(index)")
            }
            return results
        case .parallel(let nodes):
            return await withTaskGroup(of: (Int, [ActionReport.Entry]).self) { group in
                for (index, child) in nodes.enumerated() {
                    group.addTask { (index, await run(child, path: "\(path).\(index)")) }
                }
                var results: [(Int, [ActionReport.Entry])] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
            }
        case .repeated(let count, let child):
            var results: [ActionReport.Entry] = []
            for index in 0..<count { results += await run(child, path: "\(path).\(index)") }
            return results
        case .delay(let duration):
            if Task.isCancelled { return [.init(path: path, status: .notStarted, code: .cancelled)] }
            do {
                try await Task.sleep(for: duration)
                return [.init(path: path, status: .succeeded)]
            } catch { return [.init(path: path, status: .cancelled, code: .cancelled)] }
        case .action(let name, _, let budget, let executionBudget, let body):
            let leaf = "\(path).\(name)"
            if Task.isCancelled { return [.init(path: leaf, status: .notStarted, code: .cancelled)] }
            let stored = CompletionStore()
            do {
                let completion = try await ActionDeadline.run(budget: executionBudget ?? .default) {
                    let value = try await body()
                    await stored.record(value)
                    return value
                }
                if case .report(let report) = completion {
                    guard report.entries.count <= budget else {
                        return [.init(path: leaf, status: .failed, code: .resultCapacityExceeded)]
                    }
                    return Self.flatten(report, path: leaf)

                }
                // A returned completion is actual evidence; later cancellation cannot erase it.
                return [.init(path: leaf, status: .succeeded)]
            } catch {
                if error is CancellationError, let completion = await stored.completion {
                    if case .report(let report) = completion, report.entries.count <= budget {
                        return Self.flatten(report.recordingFailure(error), path: leaf)
                    }
                    if case .report = completion {
                        return [.init(path: leaf, status: .failed, code: .resultCapacityExceeded)]
                    }
                    return [.init(path: leaf, status: .succeeded)]
                }
                if let report = (error as? any ActionReportProviding)?.actionReport, report.entries.count <= budget {
                    return Self.flatten(report, path: leaf)
                }
                return [
                    .init(
                        path: leaf, status: error is CancellationError ? .cancelled : .failed,
                        code: ActionReport.code(for: error),
                        details: failureDetails(ActionReport.description(for: error)))
                ]
            }
        }
    }
}
