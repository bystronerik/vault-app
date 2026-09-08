import CryptoKit
import Foundation
import Security

/// Keeps the PIN in the Keychain as `salt (16 bytes) + SHA-256 hash (32 bytes)`.
enum PINStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Bundle.main.bundleIdentifier ?? "CalculatorVault",
        kSecAttrAccount as String: "pin",
    ]

    static func exists() -> Bool { read() != nil }

    /// 4 to 8 ASCII digits. The first digit must not be 0, because the calculator drops leading zeros.
    static func isValid(_ pin: String) -> Bool {
        (4...8).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isWholeNumber } && !pin.hasPrefix("0")
    }

    static func save(_ pin: String) throws {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        var item = query
        item[kSecValueData as String] = salt + hash(pin, salt: salt)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        delete()
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func verify(_ pin: String) -> Bool {
        guard isValid(pin), let record = read(), record.count == 48 else { return false }
        return hash(pin, salt: record.prefix(16)) == record.suffix(32)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    private static func hash(_ pin: String, salt: Data) -> Data {
        var digest = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        for _ in 0..<10_000 { digest = Data(SHA256.hash(data: digest + salt)) }
        return digest
    }

    private static func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
}
