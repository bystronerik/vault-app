import CryptoKit
import Foundation
import ImageIO
import UIKit

/// AES-256-GCM for the vault files and PBKDF2 for the PIN. CryptoKit only.
///
/// Keychain item (77 bytes): version 1, 16-byte salt, AES-GCM sealed box of the master key (combined form).
/// Vault file: `CVLT`, plaintext length (UInt64 LE), 8-byte nonce prefix, then chunks of 1 MiB plaintext
/// stored as ciphertext + 16-byte tag. The nonce of chunk `i` is the prefix + `i` (UInt32 BE).
/// The 20-byte header is the additional authenticated data of every chunk.
enum VaultCrypto {
    enum Failure: Error { case badFormat, locked, wrongPIN }

    static let rounds = 200_000
    static let chunkSize = 1 << 20
    private static let tagSize = 16
    private static let headerSize = 20
    private static let itemSize = 77
    private static let magic = Data("CVLT".utf8)

    static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    // MARK: PIN

    /// PBKDF2-HMAC-SHA256, 32 bytes. One block, so one loop.
    static func pbkdf2(pin: String, salt: Data, rounds: Int = rounds) -> SymmetricKey {
        let key = SymmetricKey(data: Data(pin.utf8))
        var u = [UInt8](HMAC<SHA256>.authenticationCode(for: salt + [0, 0, 0, 1], using: key))
        var t = u
        for _ in 1..<rounds {
            u = [UInt8](HMAC<SHA256>.authenticationCode(for: u, using: key))
            for i in 0..<32 { t[i] ^= u[i] }
        }
        return SymmetricKey(data: t)
    }

    static func isItem(_ item: Data) -> Bool { item.count == itemSize && item.first == 1 }

    /// Builds the Keychain item: a new salt and the master key sealed under the PIN.
    static func wrap(_ master: SymmetricKey, pin: String) throws -> Data {
        let salt = random(16)
        let box = try AES.GCM.seal(master.withUnsafeBytes { Data($0) }, using: pbkdf2(pin: pin, salt: salt))
        return Data([1]) + salt + box.combined!
    }

    /// Throws for a wrong PIN or a bad item.
    static func unwrap(_ item: Data, pin: String) throws -> SymmetricKey {
        guard isItem(item) else { throw Failure.badFormat }
        let box = try AES.GCM.SealedBox(combined: item.dropFirst(17))
        return try SymmetricKey(data: AES.GCM.open(box, using: pbkdf2(pin: pin, salt: item.dropFirst(1).prefix(16))))
    }

    // MARK: Files

    /// Encrypts `source` in chunks to a hidden `.part` file, then renames it to `destination`.
    static func encrypt(from source: URL, to destination: URL, key: SymmetricKey) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let header = magic + withUnsafeBytes(of: length.littleEndian) { Data($0) } + random(8)
        let part = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).part")
        guard FileManager.default.createFile(atPath: part.path, contents: header,
                                             attributes: [.protectionKey: FileProtectionType.complete]) else { throw Failure.badFormat }
        do {
            let output = try FileHandle(forWritingTo: part)
            defer { try? output.close() }
            try output.seekToEnd()
            var index: UInt32 = 0
            // The pool releases the read buffers after each chunk. Without it, they stay until the caller's pool empties.
            while try autoreleasepool(invoking: {
                guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                let box = try AES.GCM.seal(chunk, using: key, nonce: nonce(header, index), authenticating: header)
                try output.write(contentsOf: box.ciphertext + box.tag)
                index += 1
                return true
            }) {}
            try FileManager.default.moveItem(at: part, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    static func plaintextLength(_ url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try length(of: header(handle))
    }

    /// Decrypts `range` (nil: the whole file) and passes each piece to `body` in order. Reads only the chunks it needs.
    static func decrypt(_ url: URL, key: SymmetricKey, range: Range<UInt64>? = nil, into body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try header(handle)
        let total = length(of: header)
        let range = range ?? 0..<total
        guard range.upperBound <= total else { throw Failure.badFormat }
        var index = UInt32(range.lowerBound / UInt64(chunkSize))
        while UInt64(index) * UInt64(chunkSize) < range.upperBound {
            try autoreleasepool {
                let start = UInt64(index) * UInt64(chunkSize)
                let size = Int(min(UInt64(chunkSize), total - start))
                try handle.seek(toOffset: UInt64(headerSize) + UInt64(index) * UInt64(chunkSize + tagSize))
                guard let stored = try handle.read(upToCount: size + tagSize), stored.count == size + tagSize else { throw Failure.badFormat }
                let box = try AES.GCM.SealedBox(nonce: nonce(header, index), ciphertext: stored.prefix(size), tag: stored.suffix(tagSize))
                let plain = try AES.GCM.open(box, using: key, authenticating: header)
                let lo = Int(max(range.lowerBound, start) - start)
                let hi = Int(min(range.upperBound, start + UInt64(size)) - start)
                try body(plain.dropFirst(lo).prefix(hi - lo))
                index += 1
            }
        }
    }

    static func decrypt(_ url: URL, key: SymmetricKey, range: Range<UInt64>) throws -> Data {
        var out = Data()
        try decrypt(url, key: key, range: range) { out.append($0) }
        return out
    }

    static func decryptAll(_ url: URL, key: SymmetricKey) throws -> Data {
        var out = Data()
        try decrypt(url, key: key) { out.append($0) }
        return out
    }

    /// Decodes an image at not more than `maxPixelSize` on the long side, with the EXIF orientation applied.
    static func decodeImage(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func header(_ handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: headerSize), header.count == headerSize,
              header.prefix(4) == magic else { throw Failure.badFormat }
        return header
    }

    private static func length(of header: Data) -> UInt64 {
        UInt64(littleEndian: header.dropFirst(4).prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
    }

    private static func nonce(_ header: Data, _ index: UInt32) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: header.dropFirst(12) + withUnsafeBytes(of: index.bigEndian) { Data($0) })
    }

    #if DEBUG
    // swiftlint:disable force_try
    static func selfTest() {
        func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } }
        // RFC 7914 section 11, first 32 bytes.
        assert(hex(pbkdf2(pin: "passwd", salt: Data("salt".utf8), rounds: 1))
            == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
        assert(hex(pbkdf2(pin: "Password", salt: Data("NaCl".utf8), rounds: 80_000))
            == "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56")

        let key = SymmetricKey(size: .bits256)
        let item = try! wrap(key, pin: "1234")
        assert(isItem(item))
        assert(try! unwrap(item, pin: "1234") == key)
        assert((try? unwrap(item, pin: "1235")) == nil)

        let dir = URL.temporaryDirectory.appending(path: "selftest")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = Data((0..<2_621_440).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let source = dir.appending(path: "plain"), sealed = dir.appending(path: "sealed.jpg")
        try! plain.write(to: source)
        try! encrypt(from: source, to: sealed, key: key)
        assert(try! FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
        assert(try! plaintextLength(sealed) == UInt64(plain.count))
        assert(try! decryptAll(sealed, key: key) == plain)
        let range: Range<UInt64> = 1_048_000..<2_100_000
        assert(try! decrypt(sealed, key: key, range: range) == plain[Int(range.lowerBound)..<Int(range.upperBound)])

        let handle = try! FileHandle(forUpdating: sealed)
        try! handle.seek(toOffset: 40)
        let byte = try! handle.read(upToCount: 1)!
        try! handle.seek(toOffset: 40)
        try! handle.write(contentsOf: Data([byte[0] ^ 0xFF]))
        try! handle.close()
        assert((try? decryptAll(sealed, key: key)) == nil)
        assert((try? decrypt(sealed, key: key, range: 1_100_000..<1_200_000)) != nil)
    }
    // swiftlint:enable force_try
    #endif
}
