import CryptoKit
import Foundation

public enum ContentFingerprint {
    public static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}
