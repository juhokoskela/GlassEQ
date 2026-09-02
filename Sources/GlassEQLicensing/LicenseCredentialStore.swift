import Foundation
import Security

public enum LicenseCredentialStoreError: Error, Equatable, Sendable {
    /// The store itself failed. The cached state is unknown, so callers fail closed and retry.
    case keychain(OSStatus)
    /// The store answered, but the record cannot be decoded. The entitlement material is unusable
    /// and a new activation replaces it.
    case corruptRecord
}

public protocol LicenseCredentialStore: Sendable {
    func loadInstallationIdentity() throws(LicenseCredentialStoreError) -> InstallationIdentity?
    func saveInstallationIdentity(_ identity: InstallationIdentity) throws(LicenseCredentialStoreError)
    func loadActivationState() throws(LicenseCredentialStoreError) -> ActivationState?
    func saveActivationState(_ state: ActivationState) throws(LicenseCredentialStoreError)
    func clearActivationState() throws(LicenseCredentialStoreError)
}

/// Two device-only, non-synchronizable generic-password items. The Settings helper never receives
/// this store; only the main app reads or writes it.
public struct KeychainCredentialStore: LicenseCredentialStore {
    private static let service = "com.glasseq.app.licensing"

    private enum Account: String {
        case installationIdentity = "installation-identity"
        case activationState = "activation-state"
    }

    public init() {}

    public func loadInstallationIdentity() throws(LicenseCredentialStoreError) -> InstallationIdentity? {
        guard let data = try loadData(account: .installationIdentity) else {
            return nil
        }
        return try LicenseRecordCodec.decode(InstallationIdentity.self, from: data)
    }

    public func saveInstallationIdentity(_ identity: InstallationIdentity) throws(LicenseCredentialStoreError) {
        try saveData(try LicenseRecordCodec.encode(identity), account: .installationIdentity)
    }

    public func loadActivationState() throws(LicenseCredentialStoreError) -> ActivationState? {
        guard let data = try loadData(account: .activationState) else {
            return nil
        }
        return try LicenseRecordCodec.decodeActivationState(from: data)
    }

    public func saveActivationState(_ state: ActivationState) throws(LicenseCredentialStoreError) {
        try state.validate()
        try saveData(try LicenseRecordCodec.encode(state), account: .activationState)
    }

    public func clearActivationState() throws(LicenseCredentialStoreError) {
        let status = SecItemDelete(baseQuery(account: .activationState) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LicenseCredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(account: Account) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account.rawValue
        ]
    }

    private func loadData(account: Account) throws(LicenseCredentialStoreError) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw LicenseCredentialStoreError.corruptRecord
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw LicenseCredentialStoreError.keychain(status)
        }
    }

    private func saveData(_ data: Data, account: Account) throws(LicenseCredentialStoreError) {
        let query = baseQuery(account: account)
        let update: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData] = data
            attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrSynchronizable] = false
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw LicenseCredentialStoreError.keychain(status)
        }
    }
}
