import FunctionContracts

public actor ActionReportStore: FunctionReporting {
    private var report: ActionReport?
    public init() {}
    public func record(_ report: ActionReport) throws {
        guard self.report == nil else { throw ActionExecutionError.invalidCompletion }
        self.report = report
    }
    public func snapshot() -> ActionReport? { report }
}
