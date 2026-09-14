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

struct VaultItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var isVideo: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false }
}

/// The directory listing is the model. File names sort in import order.
@MainActor @Observable final class VaultStore {
    private(set) var items: [VaultItem] = []
    /// The directory that the store lists. The performance tests use a temporary directory.
    let directory: URL
    // ponytail: count limit, not strict and not LRU. Use totalCostLimit if the entry sizes differ.
    /// Decrypted thumbnails and previews, not more than 50. `Session.lock` empties it.
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
        for item in toDelete { try? FileManager.default.removeItem(at: item.url) }
        reload()
    }

    // ponytail: memory cache only, so every unlock regenerates thumbnails. Cache to disk if the grid feels slow with hundreds of items.
    /// A downscaled image for photos and the first frame for videos. `side` is in points. Nil when the file cannot open.
    static func image(for url: URL, side: CGFloat, scale: CGFloat) async -> UIImage? {
        let key = "\(Int(side))|\(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard Session.shared.masterKey != nil else { return nil }
        let pixels = Int(side * scale)
        let image: UIImage?
        if VaultItem(url: url).isVideo {
            // The generator suspends and does not block a thread, so it needs no image queue.
            let (asset, loader) = makeAsset(for: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixels, height: pixels)
            let frame = try? await generator.image(at: .zero).image
            withExtendedLifetime(loader) {}
            image = frame.map { UIImage(cgImage: $0) }
        } else {
            image = await Self.image(for: url, maxPixelSize: pixels)
        }
        // A decrypt can finish after the lock. Do not put its image back into the empty cache.
        if let image, Session.shared.masterKey != nil { cache.setObject(image, forKey: key) }
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
        try VaultCrypto.decrypt(item.url, key: key) { try output.write(contentsOf: $0) }
        return SentTransferredFile(dest)
    }
}
