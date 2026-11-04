import Foundation
import FunctionContracts
import StorageCore
import StorageFiles

public protocol ProviderCredentialStorage: Sendable {
    func key(id: String) throws -> Data?
    func insertKey(_ data: Data, id: String) throws
    func removeKey(id: String) throws
}

public struct UserSettingsDocument: Codable, Sendable {
    let version: Int
    let cloud: CloudRecord?
    var providers: [CloudRecord] = []
    var writerProviderID: String? = nil
    var writerModel: String = ""
    var writerThinking: Bool? = nil

    struct CloudRecord: Codable, Sendable {
        var name: String
        var id: String
        let enabled: Bool
        let url: String
        let model: String
        let credentialID: String
    }
}

/// Current business schema and credential references; Storage owns document consistency.
public actor ProviderSettingsStore: ProviderSettingsPersistence {
    private var document: (any DocumentStore<UserSettingsDocument>)?
    private var snapshot: DocumentSnapshot<UserSettingsDocument>?
    private var loaded = false
    private var busy = false
    private let credentials: any ProviderCredentialStorage
    private let makeDocument: @Sendable () throws -> any DocumentStore<UserSettingsDocument>
    public init(
        credentials: any ProviderCredentialStorage,
        document: @escaping @Sendable () throws -> any DocumentStore<UserSettingsDocument>
    ) {
        self.credentials = credentials
        makeDocument = document
    }

    private func documents() throws -> any DocumentStore<UserSettingsDocument> {
        if let document { return document }
        let document = try makeDocument()
        self.document = document
        return document
    }

    public func load() async throws -> ProviderSettings? {
        guard !busy else { throw ProviderSettingsError.busy }
        busy = true
        defer { busy = false }
        do {
            snapshot = try await documents().refresh()
            if let snapshot {
                guard snapshot.value.version == 1, snapshot.value.providers.count <= 32 else {
                    throw ProviderSettingsError.persistence
                }
                let current = try resolve(snapshot.value.cloud)
                let others = try snapshot.value.providers.compactMap { try resolve($0) }
                let value = current.map {
                    ProviderSettings(
                        enabled: $0.enabled, url: $0.url, key: $0.key, model: $0.model,
                        providers: others, name: $0.name, id: $0.id,
                        writerProviderID: snapshot.value.writerProviderID, writerModel: snapshot.value.writerModel,
                        writerThinking: snapshot.value.writerThinking ?? false
                    )
                }
                loaded = true
                return value
            }
            loaded = true
            return nil
        } catch {
            loaded = false
            throw error
        }
    }

    public func save(_ value: ProviderSettings?) async throws {
        guard !busy else { throw ProviderSettingsError.busy }
        guard loaded else { throw ProviderSettingsError.persistence }
        busy = true
        defer { busy = false }
        try await persist(value)
    }

    private func persist(_ value: ProviderSettings?) async throws {
        let oldIDs = ([snapshot?.value.cloud].compactMap { $0 } + (snapshot?.value.providers ?? [])).map(\.credentialID)
        var inserted: [String] = []
        do {
            var records: [UserSettingsDocument.CloudRecord] = []
            for item in (value.map { [$0] } ?? []) + (value?.providers ?? []) {
                let id = UUID().uuidString
                try credentials.insertKey(Data(item.key.utf8), id: id)
                inserted.append(id)
                let record = UserSettingsDocument.CloudRecord(
                    name: item.name, id: item.id, enabled: item.enabled, url: item.url, model: item.model,
                    credentialID: id)
                records.append(record)
            }
            let current = records.first
            let others = Array(records.dropFirst())
            var document = UserSettingsDocument(version: 1, cloud: current)
            document.providers = others
            document.writerProviderID = value?.writerProviderID
            document.writerModel = value?.writerModel ?? ""
            document.writerThinking = value?.writerThinking
            snapshot = try await documents().save(document, expecting: snapshot?.revision)
        } catch {
            for id in inserted { try? credentials.removeKey(id: id) }
            throw error
        }
        for id in oldIDs { try? credentials.removeKey(id: id) }
    }

    private func resolve(_ record: UserSettingsDocument.CloudRecord?) throws -> ProviderSettings? {
        guard let record else { return nil }
        guard let data = try credentials.key(id: record.credentialID), let key = String(data: data, encoding: .utf8)
        else {
            throw ProviderSettingsError.persistence
        }
        return ProviderSettings(
            enabled: record.enabled, url: record.url, key: key, model: record.model, name: record.name,
            id: record.id)
    }

}
