import Foundation
import ModelKit

extension OpenAIChatError {
    static func transportFailure(_ error: any Error, stage: ChatFailureDiagnostic.Stage) -> Self {
        let native = error as NSError
        guard native.domain == NSURLErrorDomain else {
            return .responseFailure(.init(.transport, stage: stage, networkReason: .other))
        }
        let kind: ChatFailureDiagnostic.NetworkReason
        switch URLError.Code(rawValue: native.code) {
        case .timedOut: kind = .timeout
        case .cannotFindHost, .dnsLookupFailed: kind = .dns
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired:
            kind = .tls
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed: kind = .offline
        case .cannotConnectToHost, .networkConnectionLost: kind = .connection
        case .cancelled: kind = .cancelled
        default: kind = .other
        }
        return .responseFailure(.init(.transport, stage: stage, networkReason: kind, networkCode: native.code))
    }
}

extension OpenAIChatConfiguration {
    func httpFailure(_ response: HTTPURLResponse, body: Data) -> OpenAIChatError {
        let document = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = document?["error"] as? [String: Any]
        return .responseFailure(
            .init(
                .httpStatus, stage: .http, statusCode: response.statusCode,
                providerCode: error?["code"] as? String,
                requestID: response.value(forHTTPHeaderField: "x-request-id")
                    ?? response.value(forHTTPHeaderField: "request-id"),
                providerType: error?["type"] as? String,
                providerParameter: error?["param"] as? String,
                providerMessage: (error?["message"] as? String).map(redactedProviderMessage)))
    }
}
