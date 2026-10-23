import Foundation
import FunctionContracts

/// Finite transition/restore acknowledgments and independent persistent-state commitment.
public protocol UIPresentationCapability: Sendable {
    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws
    func restoreExpression(invocation: any FunctionInput) async throws
    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws
}

public protocol LoadingExpressionPresentationCapability: Sendable {
    func setLoadingExpression(_ enabled: Bool, revision: UInt64, invocation: any FunctionInput) async throws
}
