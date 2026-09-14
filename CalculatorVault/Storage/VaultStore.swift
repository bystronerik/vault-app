import AVFoundation
import CryptoKit
import GRDB
import ImageIO
import os
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Application Support/Vault. The directory and every file in it use NSFileProtectionComplete.
let vaultDirectory: URL = {
    let dir = URL.applicationSupportDirectory.appending(path: "Vault")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.protectionKey: FileProtectionType.complete])
    return dir
}()

/// tmp/share. Holds the plaintext copies for the share sheet. `Session.lock` and the app launch remove it.
let shareDirectory = URL.temporaryDirectory.appending(path: "share")

/// Library/Caches/Thumbnails. Holds the encrypted grid thumbnails. The backup does not include it, and iOS can delete it.
let thumbnailDirectory: URL = {
    let dir = URL.cachesDirectory.appending(path: "Thumbnails")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.protectionKey: FileProtectionType.complete])
    return dir
}()

/// The thumbnail file of a vault file.
func thumbnailURL(for url: URL) -> URL { thumbnailDirectory.appending(path: url.lastPathComponent + ".thumb") }

/// The long side of a grid thumbnail in pixels: the cell side of 150 points at scale 3.
let thumbnailPixels = 450

private let imageQueue: OperationQueue = {
    let queue = OperationQueue()
    // ponytail: two decodes at a time. Measure a wider queue on a device if the first scroll after the update is slow.
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .userInitiated
    return queue
}()

/// Runs `work` with the master key on `imageQueue`, off the Swift concurrency pool, because an ImageIO decode blocks its thread.
/// Returns nil and skips `work` when the vault is locked or the task is cancelled before `work` starts.
private func onImageQueue<T>(_ work: @escaping (SymmetricKey) -> T?) async -> T? {
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            imageQueue.addOperation {
                guard !cancelled.withLock({ $0 }), let key = Session.shared.masterKey else { return continuation.resume(returning: nil) }
                continuation.resume(returning: work(key))
            }
        }
    } onCancel: { cancelled.withLock { $0 = true } }
}

/// Opens a thumbnail file and decodes it at not more than `maxPixelSize`. Nil when the file is missing or does not open.
private func readThumbnail(_ file: URL, key: SymmetricKey, maxPixelSize: Int) -> UIImage? {
    guard let jpeg = try? VaultCrypto.openThumbnail(file, master: key) else { return nil }
    return VaultCrypto.decodeImage(jpeg, maxPixelSize: maxPixelSize)
}

/// Writes `image` as a JPEG to the thumbnail file and returns the JPEG decoded at not more than `maxPixelSize`.
/// The result keeps no decrypted original in memory. A failed write is not an error, because the next call tries again.
private func writeThumbnail(_ image: UIImage, to file: URL, key: SymmetricKey, maxPixelSize: Int) -> UIImage? {
    // An image from ImageIO decodes the photo again at each render, and `jpegData` renders it two times.
    // So draw it one time. On the simulator, a 12 MP HEIC photo then costs one render of 70 ms, not two.
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let bitmap = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    guard let jpeg = bitmap.jpegData(compressionQuality: 0.8) else { return nil }
    try? VaultCrypto.sealThumbnail(jpeg, to: file, master: key)
    return VaultCrypto.decodeImage(jpeg, maxPixelSize: maxPixelSize)
}

struct VaultItem: Identifiable, Hashable {
    /// The row id, a UUID string. The vault file has this name, and the thumbnail file has this name plus `.thumb`.
    let id: String
    let url: URL
    /// The media type of the plaintext.
    let type: UTType
    /// The file name that the photo picker gave.
    let originalFilename: String?
    var isVideo: Bool { type.conforms(to: .movie) }
    /// The file name of the share copy.
    var shareName: String { originalFilename ?? type.preferredFilenameExtension.map { "\(id).\($0)" } ?? id }
}

/// The database of the open vault is the model. The newest capture date is first.
@MainActor @Observable final class VaultStore {
    private(set) var items: [VaultItem] = []
    // ponytail: count limit, not strict and not LRU. A removed thumbnail comes back from its file. Use totalCostLimit if the entry sizes differ.
    /// Decoded grid thumbnails, not more than 50. `Session.lock` empties it.
    static let cache = { let cache = NSCache<NSString, UIImage>(); cache.countLimit = 50; return cache }()

    init() { reload() }

    /// An item with no capture date sorts by its import date. `imported` and `id` keep the order of equal dates stable for the pager.
    func reload() {
        guard let database = Session.shared.database else { return items = [] }
        items = (try? database.read { db in
            try Array(Row.fetchCursor(db, sql: """
            SELECT id, originalFilename, type FROM item
            ORDER BY coalesce(created, imported) DESC, imported DESC, id
            """).map { row in
                let id: String = row["id"]
                return VaultItem(id: id, url: database.directory.appending(path: id), type: UTType(row["type"] as String) ?? .data,
                                 originalFilename: row["originalFilename"])
            })
        }) ?? []
    }

    func importItems(_ picks: [PhotosPickerItem]) async {
        for pick in picks {
            _ = try? await pick.loadTransferable(type: ImportedFile.self)
        }
        reload()
    }

    func delete(_ toDelete: Set<VaultItem>) {
        // The thumbnail file goes first. If the app stops between the two removals, the grid makes the thumbnail again.
        // The rows go last. If the app stops before, the grid shows the warning triangle, and a second delete removes the rows.
        for item in toDelete {
            try? FileManager.default.removeItem(at: thumbnailURL(for: item.url))
            try? FileManager.default.removeItem(at: item.url)
            Self.cache.removeObject(forKey: item.url.path as NSString)
        }
        try? Session.shared.database?.write { db in
            for item in toDelete { try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [item.id]) }
        }
        reload()
    }

    /// The grid thumbnail of a photo or a video: the JPEG of not more than 450 pixels from the thumbnail file, decoded at not more
    /// than `maxPixelSize`. Makes the thumbnail file when it is missing or does not open. Nil when the vault file cannot open.
    static func thumbnail(for item: VaultItem, maxPixelSize: Int = thumbnailPixels) async -> UIImage? {
        let cacheKey = item.url.path as NSString
        // The cache holds only full-size thumbnails, so a cached image is large enough for each request.
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let file = thumbnailURL(for: item.url)
        let image: UIImage?
        if item.isVideo {
            if let saved = await onImageQueue({ readThumbnail(file, key: $0, maxPixelSize: maxPixelSize) }) {
                image = saved
            } else {
                // The generator suspends and does not block a thread, so it needs no image queue.
                let (asset, loader) = makeAsset(for: item)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: thumbnailPixels, height: thumbnailPixels)
                let frame = try? await generator.image(at: .zero).image
                withExtendedLifetime(loader) {}
                guard let frame else { return nil }
                image = await onImageQueue { writeThumbnail(UIImage(cgImage: frame), to: file, key: $0, maxPixelSize: maxPixelSize) }
            }
        } else {
            // One operation for the read, the decode, and the write. A second operation for the write would wait behind
            // the decodes of all other cells, and each waiting image would keep its decrypted original.
            image = await onImageQueue { key in
                if let saved = readThumbnail(file, key: key, maxPixelSize: maxPixelSize) { return saved }
                guard let data = try? VaultCrypto.decryptAll(item.url, key: key),
                      let decoded = VaultCrypto.decodeImage(data, maxPixelSize: thumbnailPixels) else { return nil }
                return writeThumbnail(decoded, to: file, key: key, maxPixelSize: maxPixelSize)
            }
        }
        // A decrypt can finish after the lock. Do not put its image back into the empty cache.
        if let image, maxPixelSize >= thumbnailPixels, Session.shared.masterKey != nil { cache.setObject(image, forKey: cacheKey) }
        return image
    }

    /// Decrypts a photo and decodes it at not more than `maxPixelSize` pixels on the long side. Does not use the cache.
    static func image(for url: URL, maxPixelSize: Int) async -> UIImage? {
        await onImageQueue { key in
            guard let data = try? VaultCrypto.decryptAll(url, key: key) else { return nil }
            return VaultCrypto.decodeImage(data, maxPixelSize: maxPixelSize)
        }
    }
}

/// Encrypts a picked photo or video into the vault directory and adds its row to the database. The app writes no plaintext copy.
struct ImportedFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try await Self(copying: $0.file, contentType: .movie) }
        FileRepresentation(importedContentType: .image) { try await Self(copying: $0.file, contentType: .image) }
    }

    /// The insert of the row runs before the rename. If the insert or the save throws, no vault file stays without a row.
    /// A lock during the import has the same result, because the write throws after the close.
    init(copying source: URL, contentType: UTType) async throws {
        guard let key = Session.shared.masterKey, let database = Session.shared.database else { throw VaultCrypto.Failure.locked }
        let id = UUID().uuidString
        // For an extension that the system does not know, UTType gives a dynamic type.
        let type = UTType(filenameExtension: source.pathExtension).flatMap { $0.isDynamic ? nil : $0 } ?? contentType
        let created = await Self.captureDate(of: source, isVideo: type.conforms(to: .movie))
        try VaultCrypto.encrypt(from: source, to: database.directory.appending(path: id), key: key) {
            try database.write { db in
                try db.execute(sql: "INSERT INTO item (id, originalFilename, type, created, imported) VALUES (?, ?, ?, ?, ?)",
                               arguments: [id, source.lastPathComponent, type.identifier, created, Date()])
            }
        }
    }

    /// The EXIF DateTimeOriginal of a photo, or the creation date in the metadata of a video. Nil when it is missing or does not parse.
    private static func captureDate(of source: URL, isVideo: Bool) async -> Date? {
        if isVideo { return try? await AVURLAsset(url: source).load(.creationDate)?.load(.dateValue) }
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return exifDate(original, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
    }

    /// Parses an EXIF date, for example "2019:06:01 12:00:00" with the offset "+02:00". With no offset, the current time zone applies.
    private static func exifDate(_ date: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssXXXXX"
        return formatter.date(from: date + (offset ?? ""))
    }

    #if DEBUG
    static func selfTest() {
        assert(exifDate("2019:06:01 12:00:00", offset: "+02:00") == Date(timeIntervalSince1970: 1_559_383_200))
        assert(exifDate("2019:06:01 12:00:00", offset: nil) == Calendar.current.date(from: DateComponents(year: 2019, month: 6, day: 1, hour: 12)))
        assert(exifDate("0000:00:00 00:00:00", offset: nil) == nil)
    }
    #endif
}

/// Decrypts an item to tmp/share for the share sheet. The mirror of `ImportedFile`.
struct VaultExport: Transferable {
    let item: VaultItem

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { try $0.file() }.exportingCondition { $0.item.isVideo }
        FileRepresentation(exportedContentType: .image) { try $0.file() }.exportingCondition { !$0.item.isVideo }
    }

    private func file() throws -> SentTransferredFile {
        guard let key = Session.shared.masterKey else { throw VaultCrypto.Failure.locked }
        // A directory for each item, so two items with the same original filename do not replace each other.
        let directory = shareDirectory.appending(path: item.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let dest = directory.appending(path: item.shareName)
        try? FileManager.default.removeItem(at: dest)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.complete]) else { throw VaultCrypto.Failure.badFormat }
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }
        do {
            try VaultCrypto.decrypt(item.url, key: key) {
                guard Session.shared.masterKey != nil else { throw VaultCrypto.Failure.locked }
                try output.write(contentsOf: $0)
            }
        } catch {
            // Do not keep a partial plaintext copy until the next lock.
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return SentTransferredFile(dest)
    }
}
