import CommonCrypto
import CryptoKit
import Foundation
import ImageIO
import UIKit

/// AES-256-GCM for the vault files, the thumbnail files, and the database file, and PBKDF2 for the PIN. System crypto only.
///
/// Keys: a PBKDF2 key of the PIN wraps the master key. HKDF-SHA256 derives the thumbnail key, the database key, and the
/// file wrap key from the master key. The file wrap key wraps the random file key of each vault file (AES key wrap,
/// RFC 3394).
/// Keychain item (77 bytes): version 1, 16-byte salt, AES-GCM sealed box of the master key (combined form).
/// Vault file, version 2: `CVL2`, plaintext length (UInt64 LE), 8-byte nonce prefix, 40-byte wrapped file key, then
/// chunks of 1 MiB plaintext stored as ciphertext + 16-byte tag under the file key. The nonce of chunk `i` is the
/// prefix + `i` (UInt32 BE). Header bytes 0 to 19 are the additional authenticated data of every chunk, so a new wrap
/// of the file key changes only bytes 20 to 59. A file with the length 0 has no chunk, so no tag checks its header.
/// Thumbnail file: a JPEG in the AES-GCM combined form (12-byte random nonce, ciphertext, 16-byte tag) under the
/// thumbnail key. HKDF-SHA256 derives the thumbnail key from the master key.
/// Database file: the bytes of the SQLite database in the same AES-GCM combined form under the database key.
enum VaultCrypto {
    enum Failure: Error { case badFormat, locked, wrongPIN }

    static let rounds = 200_000
    static let chunkSize = 1 << 20
    private static let tagSize = 16
    /// Header bytes 0 to 19: the magic, the length, and the nonce prefix. The wrapped file key follows them.
    private static let headerSize = 20
    private static let wrappedKeySize = 40
    private static let itemSize = 77
    private static let magicV2 = Data("CVL2".utf8)

    static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    // MARK: PIN

    /// PBKDF2-HMAC-SHA256, 32 bytes, from CommonCrypto. It gives the same output as the Swift loop of older builds,
    /// about 20 times faster. The attacker cost does not change.
    static func pbkdf2(pin: String, salt: Data, rounds: Int = rounds) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pin, pin.utf8.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, out.count)
        }
        precondition(status == kCCSuccess)
        return SymmetricKey(data: out)
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

    // MARK: Thumbnails and database

    /// A key for one use, derived from the master key. The app does not store it.
    private static func subkey(_ master: SymmetricKey, _ info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data(info.utf8), outputByteCount: 32)
    }

    /// Writes a thumbnail file: the AES-GCM combined form under the thumbnail key. Replaces an existing file.
    static func sealThumbnail(_ jpeg: Data, to url: URL, master: SymmetricKey) throws {
        try seal(jpeg, to: url, key: subkey(master, "CalculatorVault thumbnail"))
    }

    /// Reads a thumbnail file. Throws when the file is missing or does not open.
    static func openThumbnail(_ url: URL, master: SymmetricKey) throws -> Data {
        try open(url, key: subkey(master, "CalculatorVault thumbnail"))
    }

    /// Writes the database file: the AES-GCM combined form under the database key. Replaces an existing file.
    static func sealDatabase(_ bytes: Data, to url: URL, master: SymmetricKey) throws {
        try seal(bytes, to: url, key: subkey(master, "CalculatorVault database"))
    }

    /// Reads the database file. Throws when the file is missing or does not open.
    static func openDatabase(_ url: URL, master: SymmetricKey) throws -> Data {
        try open(url, key: subkey(master, "CalculatorVault database"))
    }

    /// Writes the AES-GCM combined form. The atomic write keeps the previous file if the app stops during the write.
    private static func seal(_ plaintext: Data, to url: URL, key: SymmetricKey) throws {
        try AES.GCM.seal(plaintext, using: key).combined!.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func open(_ url: URL, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key)
    }

    // MARK: Files

    /// Encrypts `source` in chunks to a hidden `.part` file, runs `beforeRename`, and renames the file to `destination`.
    /// Writes version 2. If a step throws, the function removes the `.part` file.
    static func encrypt(from source: URL, to destination: URL, key: SymmetricKey, beforeRename: () throws -> Void = {}) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let fileKey = SymmetricKey(size: .bits256)
        let header = try magicV2 + withUnsafeBytes(of: length.littleEndian) { Data($0) } + random(8)
            + AES.KeyWrap.wrap(fileKey, using: subkey(key, "CalculatorVault file key"))
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
                let box = try AES.GCM.seal(chunk, using: fileKey, nonce: nonce(header, index), authenticating: header.prefix(headerSize))
                try output.write(contentsOf: box.ciphertext + box.tag)
                index += 1
                return true
            }) {}
            try beforeRename()
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
        // The key wrap checks the wrapped key, so a changed byte throws.
        let fileKey = try AES.KeyWrap.unwrap(header.dropFirst(headerSize), using: subkey(key, "CalculatorVault file key"))
        let total = length(of: header)
        let range = range ?? 0..<total
        guard range.upperBound <= total else { throw Failure.badFormat }
        var index = UInt32(range.lowerBound / UInt64(chunkSize))
        while UInt64(index) * UInt64(chunkSize) < range.upperBound {
            try autoreleasepool {
                let start = UInt64(index) * UInt64(chunkSize)
                let size = Int(min(UInt64(chunkSize), total - start))
                try handle.seek(toOffset: UInt64(header.count) + UInt64(index) * UInt64(chunkSize + tagSize))
                guard let stored = try handle.read(upToCount: size + tagSize), stored.count == size + tagSize else { throw Failure.badFormat }
                let box = try AES.GCM.SealedBox(nonce: nonce(header, index), ciphertext: stored.prefix(size), tag: stored.suffix(tagSize))
                let plain = try AES.GCM.open(box, using: fileKey, authenticating: header.prefix(headerSize))
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

    /// The header: 60 bytes with the wrapped file key.
    private static func header(_ handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: headerSize + wrappedKeySize), header.count == headerSize + wrappedKeySize,
              header.prefix(4) == magicV2 else { throw Failure.badFormat }
        return header
    }

    private static func length(of header: Data) -> UInt64 {
        UInt64(littleEndian: header.dropFirst(4).prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
    }

    private static func nonce(_ header: Data, _ index: UInt32) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: header.dropFirst(12).prefix(8) + withUnsafeBytes(of: index.bigEndian) { Data($0) })
    }

    #if DEBUG
    // swiftlint:disable force_try
    static func selfTest() {
        func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } }
        func bytes(_ hex: String) -> Data { Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }) }
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

        let thumbnail = dir.appending(path: "thumbnail")
        try! sealThumbnail(plain.prefix(1_000), to: thumbnail, master: key)
        assert(try! openThumbnail(thumbnail, master: key) == plain.prefix(1_000))
        assert((try? openThumbnail(thumbnail, master: SymmetricKey(size: .bits256))) == nil)

        // The wrapped key of another file gives another file key, so the chunk tags fail.
        let other = dir.appending(path: "other.jpg")
        try! encrypt(from: source, to: other, key: key)
        var otherData = try! Data(contentsOf: other)
        try! otherData.replaceSubrange(20..<60, with: Data(contentsOf: sealed)[20..<60])
        try! otherData.write(to: other)
        assert((try? decryptAll(other, key: key)) == nil)

        // Offset 80 is in the first chunk. A changed byte in the header makes the whole file fail.
        let handle = try! FileHandle(forUpdating: sealed)
        try! handle.seek(toOffset: 80)
        let byte = try! handle.read(upToCount: 1)!
        try! handle.seek(toOffset: 80)
        try! handle.write(contentsOf: Data([byte[0] ^ 0xFF]))
        try! handle.close()
        assert((try? decryptAll(sealed, key: key)) == nil)
        assert((try? decrypt(sealed, key: key, range: 1_100_000..<1_200_000)) != nil)

        // Fixed files: master key bytes 00 to 1f, file key bytes 20 to 3f, nonce prefix 01 to 08, database nonce 01 to 0c.
        // A change of the HKDF info, the header layout, or the additional authenticated data makes them fail.
        let master = SymmetricKey(data: Data(0..<32))
        let v2 = dir.appending(path: "v2.jpg"), database = dir.appending(path: "database")
        try! bytes("43564c3207000000000000000102030405060708e70688b971db6407c7b727d9a032202c508f5947f81b88b07e"
            + "1455874ac5d32a7543d77127acdfe31ec2cd24e5c0435c94014f304d00112cd36b70f787e459").write(to: v2)
        assert(try! decryptAll(v2, key: master) == Data("v2 test".utf8))
        try! bytes("0102030405060708090a0b0caadb465f2426cf4fd5de1d0c52ed0df4106dee0552131dc6f4cc65b429").write(to: database)
        assert(try! openDatabase(database, master: master) == Data("database test".utf8))
    }
    // swiftlint:enable force_try
    #endif
}
