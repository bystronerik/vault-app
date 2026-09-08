import CryptoKit
import Foundation
import Security

/// Keeps the wrapped master key in the Keychain. See `VaultCrypto` for the item format.
/// The item has no `ThisDeviceOnly` accessibility, so it migrates in the iCloud device backup.
enum PINStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Bundle.main.bundleIdentifier ?? "CalculatorVault",
        kSecAttrAccount as String: "pin",
    ]

    /// True only for an item in the current format. A leftover old item counts as absent.
    static func exists() -> Bool { read().map(VaultCrypto.isItem) ?? false }

    /// 4 to 8 ASCII digits. The first digit must not be 0, because the calculator drops leading zeros.
    static func isValid(_ pin: String) -> Bool {
        (4...8).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isWholeNumber } && !pin.hasPrefix("0")
    }

    /// Makes a new master key and writes it wrapped under `pin`.
    static func save(_ pin: String) throws {
        try write(VaultCrypto.wrap(SymmetricKey(size: .bits256), pin: pin))
    }

    /// The master key, or nil for a wrong PIN or a missing item.
    static func unlock(_ pin: String) -> SymmetricKey? {
        guard isValid(pin), let item = read() else { return nil }
        return try? VaultCrypto.unwrap(item, pin: pin)
    }

    /// Wraps the same master key under the new PIN. The vault files do not change.
    static func change(from old: String, to new: String) throws {
        guard let key = unlock(old) else { throw VaultCrypto.Failure.wrongPIN }
        try write(VaultCrypto.wrap(key, pin: new))
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    private static func write(_ item: Data) throws {
        var q = query
        q[kSecValueData as String] = item
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        delete()
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
}
