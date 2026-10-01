import AgentCore
import Foundation

/// Validated finite tree; children inherit the root's resource fence, never reacquire it.
public struct ActionComposition: Sendable {
    public indirect enum Node: Sendable {
        case action(
            String, Set<ResourceID>, maximumResults: Int = 1, budget: ActionExecutionBudget? = nil,
            @Sendable () async throws -> ActionCompletion)
        case sequence([Node])
        case parallel([Node])
        case repeated(Int, Node)
        case delay(Duration)
    }
    public enum ConfigurationError: Error { case limit, overlappingResources, invalidDelay }
    private let root: Node
    public let resources: Set<ResourceID>
    public init(_ root: Node) throws {
        let validated = try Self.validate(root, depth: 0)
        guard validated.count <= 256, validated.resources.count <= 8 else { throw ConfigurationError.limit }
        self.root = root
        resources = validated.resources
    }
    private static func validate(_ node: Node, depth: Int) throws -> (count: Int, resources: Set<ResourceID>) {
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
            var resources: Set<ResourceID> = []
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
    /// Nil means at least one child has no declared estimate; never invent a fixed deadline.
    public var executionBudget: ActionExecutionBudget? { get throws { try Self.budget(root) } }
    private static func budget(_ node: Node) throws -> ActionExecutionBudget? {
        switch node {
        case .action(_, _, _, let budget, _): return budget
        case .delay(let duration):
            return try ActionExecutionBudget(expected: duration, timeout: duration + .milliseconds(100))
        case .repeated(let count, let child):
            guard let value = try budget(child) else { return nil }
            return try .sequence(Array(repeating: value, count: count))
        case .sequence(let nodes), .parallel(let nodes):
            let budgets = try nodes.compactMap { try budget($0) }
            guard budgets.count == nodes.count, !budgets.isEmpty else { return nil }
            if case .parallel = node { return try .parallel(budgets) }
            return try .sequence(budgets)
        }
    }
    private static func flatten(_ report: ActionReport, path: String) -> [ActionReport.Entry] {
        var entries = report.entries.map {
            ActionReport.Entry(
                path: "\(path).\($0.path)",
                status: report.executionFailure == .timedOut && $0.code == .cancelled ? .failed : $0.status,
                code: report.executionFailure == .timedOut && $0.code == .cancelled ? .timedOut : $0.code,
                motor: $0.motor, target: $0.target, observed: $0.observed)
        }
        if let code = report.executionFailure {
            entries.append(.init(path: "\(path).execution", status: .failed, code: code))
        }
        return entries
    }
    public func run() async throws -> ActionReport {
        try ActionReport(entries: await Self.run(root, path: "root"))
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
            do {
                let completion: ActionCompletion
                if let executionBudget {
                    completion = try await ActionDeadline.run(budget: executionBudget, body: body)
                } else {
                    completion = try await body()
                }
                if case .report(let report) = completion {
                    guard report.entries.count <= budget else {
                        return [.init(path: leaf, status: .failed, code: .resultCapacityExceeded)]
                    }
                    return Self.flatten(report, path: leaf)

                }
                return [
                    .init(
                        path: leaf, status: Task.isCancelled ? .cancelled : .succeeded,
                        code: Task.isCancelled ? .cancelled : nil)
                ]
            } catch {
                if let report = (error as? any ActionReportProviding)?.actionReport, report.entries.count <= budget {
                    return Self.flatten(report, path: leaf)
                }
                return [
                    .init(
                        path: leaf, status: error is CancellationError ? .cancelled : .failed,
                        code: ActionReport.code(for: error))
                ]
            }
        }
    }
}
