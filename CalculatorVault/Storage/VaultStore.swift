import AVFoundation
import CryptoKit
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
    let url: URL
    var id: URL { url }
    var isVideo: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false }
}

/// The directory listing is the model. File names sort in import order.
@MainActor @Observable final class VaultStore {
    private(set) var items: [VaultItem] = []
    /// The directory that the store lists. The performance tests use a temporary directory.
    /// The thumbnail files are always in `thumbnailDirectory`.
    let directory: URL
    // ponytail: count limit, not strict and not LRU. A removed thumbnail comes back from its file. Use totalCostLimit if the entry sizes differ.
    /// Decoded grid thumbnails, not more than 50. `Session.lock` empties it.
    static let cache = { let cache = NSCache<NSString, UIImage>(); cache.countLimit = 50; return cache }()

    init(directory: URL = vaultDirectory) {
        self.directory = directory
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                 options: .skipsHiddenFiles)) ?? []
        // Get each name one time. `lastPathComponent` in the comparison made the sort 3 times slower.
        items = urls.map { ($0.lastPathComponent, $0) }.sorted { $0.0 < $1.0 }.map { VaultItem(url: $0.1) }
    }

    func importItems(_ picks: [PhotosPickerItem]) async {
        for pick in picks {
            _ = try? await pick.loadTransferable(type: ImportedFile.self)
        }
        reload()
    }

    func delete(_ toDelete: Set<VaultItem>) {
        // The thumbnail file goes first. If the app stops between the two removals, the grid makes the thumbnail again.
        for item in toDelete {
            try? FileManager.default.removeItem(at: thumbnailURL(for: item.url))
            try? FileManager.default.removeItem(at: item.url)
            Self.cache.removeObject(forKey: item.url.path as NSString)
        }
        reload()
    }

    /// The grid thumbnail of a photo or a video: the JPEG of not more than 450 pixels from the thumbnail file, decoded at not more
    /// than `maxPixelSize`. Makes the thumbnail file when it is missing or does not open. Nil when the vault file cannot open.
    static func thumbnail(for url: URL, maxPixelSize: Int = thumbnailPixels) async -> UIImage? {
        let cacheKey = url.path as NSString
        // The cache holds only full-size thumbnails, so a cached image is large enough for each request.
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let file = thumbnailURL(for: url)
        let image: UIImage?
        if VaultItem(url: url).isVideo {
            if let saved = await onImageQueue({ readThumbnail(file, key: $0, maxPixelSize: maxPixelSize) }) {
                image = saved
            } else {
                // The generator suspends and does not block a thread, so it needs no image queue.
                let (asset, loader) = makeAsset(for: url)
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
                guard let data = try? VaultCrypto.decryptAll(url, key: key),
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

/// Encrypts a picked photo or video into the vault directory. The app writes no plaintext copy.
struct ImportedFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try Self(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try Self(copying: $0.file) }
    }

    init(copying source: URL) throws {
        guard let key = Session.shared.masterKey else { throw VaultCrypto.Failure.locked }
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        let dest = vaultDirectory.appending(path: name).appendingPathExtension(source.pathExtension)
        try VaultCrypto.encrypt(from: source, to: dest, key: key)
    }
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
        try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let dest = shareDirectory.appending(path: item.url.lastPathComponent)
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
