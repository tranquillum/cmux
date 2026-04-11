import Foundation
import Security

@MainActor
final class ProviderAccountStore: ObservableObject {
    static let shared = ProviderAccountStore()

    @Published private(set) var accounts: [ProviderAccount] = []

    private static let defaultIndexKey = "cmux.providers.accounts.index"

    private let userDefaults: UserDefaults
    private let indexKey: String

    /// Resolves the keychain service name for a given providerId via ProviderRegistry.
    /// Falls back to "com.cmuxterm.app.<providerId>-accounts" if the provider is not registered.
    var keychainServiceResolver: (String) -> String = { providerId in
        ProviderRegistry.provider(id: providerId)?.keychainService
            ?? "com.cmuxterm.app.\(providerId)-accounts"
    }

    private init() {
        self.userDefaults = .standard
        self.indexKey = Self.defaultIndexKey
        self.accounts = loadIndex()
    }

    /// Initializer for tests only. Injects an isolated `UserDefaults`
    /// suite and an index key so unit tests don't pollute (or read from)
    /// the shared defaults domain used by `.shared`. Production code must
    /// always go through `ProviderAccountStore.shared`; this module-internal
    /// init exists purely so `cmuxTests/ProviderTests.swift` can round-trip
    /// the store against a throwaway suite.
    init(userDefaults: UserDefaults, indexKey: String) {
        self.userDefaults = userDefaults
        self.indexKey = indexKey
        self.accounts = loadIndex()
    }

    // MARK: - Public API
    //
    // Keychain-touching operations are `async` so the synchronous `SecItem*`
    // calls run on a detached task instead of blocking the MainActor while
    // the system Keychain resolves. `@Published accounts` mutations stay on
    // main so SwiftUI observers don't need to hop actors.

    func reload() {
        accounts = loadIndex()
    }

    func add(providerId: String, displayName: String, secret: ProviderSecret) async throws {
        guard ProviderRegistry.provider(id: providerId) != nil else {
            throw ProviderAccountStoreError.notFound
        }
        let service = keychainServiceResolver(providerId)
        let account = ProviderAccount(
            id: UUID(),
            providerId: providerId,
            displayName: displayName,
            keychainService: service
        )
        try await ProviderAccountKeychain.save(secret: secret, for: account.id, service: service)
        var current = accounts
        current.append(account)
        do {
            try saveIndex(current)
        } catch {
            // Undo the keychain write if we can't persist the index — otherwise
            // the credential would linger without a referencing account.
            try? await ProviderAccountKeychain.delete(for: account.id, service: service)
            throw error
        }
        accounts = current
    }

    func update(id: UUID, displayName: String, secret: ProviderSecret) async throws {
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw ProviderAccountStoreError.notFound
        }
        let service = serviceName(for: account)
        // Keep the existing credentials on hand so a failure to persist the
        // index can roll the keychain back; otherwise on-disk state could drift
        // behind a successful keychain write.
        let previousSecret = try? await ProviderAccountKeychain.load(for: id, service: service)
        try await ProviderAccountKeychain.update(secret: secret, for: id, service: service)
        // Actor reentrancy: another caller could have mutated `accounts` during
        // the keychain awaits above, so look the row up fresh before touching
        // it instead of trusting a snapshot taken beforehand.
        var current = accounts
        guard let index = current.firstIndex(where: { $0.id == id }) else {
            if let previousSecret {
                try? await ProviderAccountKeychain.update(secret: previousSecret, for: id, service: service)
            }
            throw ProviderAccountStoreError.notFound
        }
        current[index].displayName = displayName
        do {
            try saveIndex(current)
        } catch {
            if let previousSecret {
                try? await ProviderAccountKeychain.update(secret: previousSecret, for: id, service: service)
            }
            throw error
        }
        accounts = current
    }

    func remove(id: UUID) async throws {
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw ProviderAccountStoreError.notFound
        }
        let service = serviceName(for: account)
        // Delete the keychain secret first so a failure surfaces to the caller
        // before any on-disk state changes. That way a "removed" account never
        // lingers in the index with live credentials still on disk.
        try await ProviderAccountKeychain.delete(for: id, service: service)
        var current = accounts
        current.removeAll { $0.id == id }
        try saveIndex(current)
        accounts = current
    }

    func secret(for id: UUID) async throws -> ProviderSecret {
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw ProviderAccountStoreError.notFound
        }
        let service = serviceName(for: account)
        return try await ProviderAccountKeychain.load(for: id, service: service)
    }

    /// Resolves the keychain service to target for an account. A value stored
    /// at account creation wins; when the field is missing (accounts written
    /// by earlier builds) the registry resolver provides the fallback.
    private func serviceName(for account: ProviderAccount) -> String {
        account.keychainService ?? keychainServiceResolver(account.providerId)
    }

    // MARK: - Index Persistence (UserDefaults)

    private func loadIndex() -> [ProviderAccount] {
        guard let data = userDefaults.data(forKey: indexKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([ProviderAccount].self, from: data)
        } catch {
            // Surface decode failures so corrupted index data doesn't silently
            // hide stored accounts and their keychain credentials.
            NSLog("ProviderAccountStore: failed to decode account index (\(data.count) bytes): \(error)")
            return []
        }
    }

    private func saveIndex(_ accounts: [ProviderAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        userDefaults.set(data, forKey: indexKey)
    }
}

// MARK: - Keychain I/O (nonisolated)
//
// Kept separate from the MainActor-isolated store so that synchronous
// `SecItem*` calls run on a detached task without leaking their blocking
// behavior to the UI. Every call routes through `matchQuery` /
// `addAttributes` so accessibility + synchronizability attributes stay
// consistent:
//
//   - kSecAttrAccessibleWhenUnlockedThisDeviceOnly — the credential is
//     reachable while the device is unlocked and never migrates via
//     Time Machine or iCloud keychain restore to a different machine.
//     AI provider session tokens are inherently tied to the current
//     machine's sign-in; they should not follow a user restore.
//   - kSecAttrSynchronizable = kCFBooleanFalse — explicit opt-out of
//     iCloud Keychain sync so a future default flip can't pick these
//     items up without a code change. The attribute is part of both
//     the match query and the write attributes so stored items and
//     lookups stay perfectly symmetric.

enum ProviderAccountKeychain {
    /// Each entry point pre-checks cancellation and propagates it into the
    /// detached task via `withTaskCancellationHandler`. The underlying
    /// `SecItem*` calls are synchronous and not themselves interruptible, so
    /// a keychain call already in flight still runs to completion — but an
    /// upstream cancellation reaches the work before it starts and reaches
    /// every subsequent call afterwards.
    static func save(secret: ProviderSecret, for accountId: UUID, service: String) async throws {
        try Task.checkCancellation()
        try await runDetached {
            try writeAdd(secret, for: accountId, service: service)
        }
    }

    static func update(secret: ProviderSecret, for accountId: UUID, service: String) async throws {
        try Task.checkCancellation()
        try await runDetached {
            try writeUpdate(secret, for: accountId, service: service)
        }
    }

    static func load(for accountId: UUID, service: String) async throws -> ProviderSecret {
        try Task.checkCancellation()
        return try await runDetached {
            try readLoad(for: accountId, service: service)
        }
    }

    static func delete(for accountId: UUID, service: String) async throws {
        try Task.checkCancellation()
        try await runDetached {
            try writeDelete(for: accountId, service: service)
        }
    }

    private static func runDetached<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try work()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Synchronous internals

    private static func matchQuery(service: String, accountId: UUID) -> [CFString: Any] {
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountId.uuidString,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }

    private static func addAttributes(payload: Data) -> [CFString: Any] {
        return [
            kSecValueData: payload,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }

    private static func encodeSecret(_ secret: ProviderSecret) throws -> Data {
        try JSONEncoder().encode(secret.fields)
    }

    private static func decodeSecret(_ data: Data) throws -> ProviderSecret {
        do {
            let fields = try JSONDecoder().decode([String: String].self, from: data)
            return ProviderSecret(fields: fields)
        } catch {
            throw ProviderAccountStoreError.decoding
        }
    }

    private static func writeAdd(_ secret: ProviderSecret, for accountId: UUID, service: String) throws {
        let payload = try encodeSecret(secret)
        var query = matchQuery(service: service, accountId: accountId)
        query.merge(addAttributes(payload: payload)) { _, new in new }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let deleteQuery = matchQuery(service: service, accountId: accountId)
            SecItemDelete(deleteQuery as CFDictionary)
            let retryStatus = SecItemAdd(query as CFDictionary, nil)
            if retryStatus != errSecSuccess {
                throw ProviderAccountStoreError.keychain(retryStatus)
            }
        } else if status != errSecSuccess {
            throw ProviderAccountStoreError.keychain(status)
        }
    }

    private static func writeUpdate(_ secret: ProviderSecret, for accountId: UUID, service: String) throws {
        let payload = try encodeSecret(secret)
        let query = matchQuery(service: service, accountId: accountId)
        let attributes = addAttributes(payload: payload)
        // Strict update-only: if the item has vanished between the caller's
        // `load(...)` and this write (e.g. a concurrent `remove(id:)` ran
        // during the intervening await), surface `errSecItemNotFound` instead
        // of silently re-creating an orphan credential that no index entry
        // references.
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            throw ProviderAccountStoreError.keychain(status)
        }
    }

    private static func readLoad(for accountId: UUID, service: String) throws -> ProviderSecret {
        var query = matchQuery(service: service, accountId: accountId)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProviderAccountStoreError.keychain(status)
        }
        return try decodeSecret(data)
    }

    private static func writeDelete(for accountId: UUID, service: String) throws {
        let query = matchQuery(service: service, accountId: accountId)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw ProviderAccountStoreError.keychain(status)
        }
    }
}
