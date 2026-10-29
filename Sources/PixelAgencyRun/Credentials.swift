import CryptoKit
import Foundation
import MESClientKit
import MESCore
import Security

/// Where a client keeps what pairing gives it (Base §5): its own identity, and per engine the pinned certificate and
/// the bearer token. Both are secrets, so the app keeps them in the Keychain; tests use `MemoryCredentialStore`.
public protocol CredentialStore: Sendable {
    /// This client's identity, created on first use.
    func identity(name: String) throws -> ClientIdentity
    func pairings() -> [PairedEngine]
    func save(_ engine: PairedEngine) throws
    func remove(engineID: String) throws
}

/// The Keychain (generic passwords, service `PixelAgency.*`), readable only by this app.
public struct KeychainCredentialStore: CredentialStore {
    let prefix: String

    /// `prefix` separates apps (and tests) sharing a keychain: `PixelAgency.Lite`, `PixelAgency.Desktop`.
    public init(prefix: String = "PixelAgency.Lite") { self.prefix = prefix }

    struct StoredIdentity: Codable { var id: String; var name: String; var key: String }

    public func identity(name: String) throws -> ClientIdentity {
        if let data = read(service: "\(prefix).identity", account: "client"),
           let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           let raw = Data(base64Encoded: stored.key), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return ClientIdentity(id: stored.id, name: name, key: key)
        }
        let identity = ClientIdentity.generate(name: name)
        let stored = StoredIdentity(id: identity.id, name: name, key: identity.rawKey.base64EncodedString())
        try write(try JSONEncoder().encode(stored), service: "\(prefix).identity", account: "client")
        return identity
    }

    /// Lists the accounts, then reads each item: the file-based keychain (every Mac process that doesn't opt into the
    /// data protection keychain, sandboxed or not) refuses data for several items in one query with `errSecParam`.
    public func pairings() -> [PairedEngine] {
        let service = "\(prefix).pairing"
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[CFString: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount] as? String }
            .compactMap { read(service: service, account: $0).flatMap { try? MESJSON.decoder.decode(PairedEngine.self, from: $0) } }
    }

    public func save(_ engine: PairedEngine) throws {
        try write(try MESJSON.encoder.encode(engine), service: "\(prefix).pairing", account: engine.engineID)
    }

    public func remove(engineID: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "\(prefix).pairing", kSecAttrAccount: engineID]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func read(service: String, account: String) -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")" }
}

/// Credentials in memory, for tests and for `pa-run`.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var client: ClientIdentity?
    private var stored: [String: PairedEngine] = [:]

    public init() {}

    public func identity(name: String) throws -> ClientIdentity {
        lock.withLock {
            if let client { return client }
            let created = ClientIdentity.generate(name: name)
            client = created
            return created
        }
    }

    public func pairings() -> [PairedEngine] { lock.withLock { Array(stored.values) } }
    public func save(_ engine: PairedEngine) throws { lock.withLock { stored[engine.engineID] = engine } }
    public func remove(engineID: String) throws { _ = lock.withLock { stored.removeValue(forKey: engineID) } }
}
