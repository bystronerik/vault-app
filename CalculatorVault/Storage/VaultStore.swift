import AVFoundation
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

/// tmp/share. Holds the plaintext copies for the share sheet. `Session.lock` removes it.
let shareDirectory = URL.temporaryDirectory.appending(path: "share")

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
    /// Decrypted thumbnails and previews. `Session.lock` empties it.
    static let cache = NSCache<NSString, UIImage>()

    init(directory: URL = vaultDirectory) {
        self.directory = directory
        // A crash or a lock during an import leaves a `.part` file. Delete it at the vault open.
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in all where url.pathExtension == "part" { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                 options: .skipsHiddenFiles)) ?? []
        items = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(VaultItem.init)
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

    /// A downscaled image for photos and the first frame for videos. `side` is in points. Nil when the file cannot open.
    // ponytail: memory cache only, so every unlock regenerates thumbnails. Cache to disk if the grid feels slow with hundreds of items.
    static func image(for url: URL, side: CGFloat, scale: CGFloat) async -> UIImage? {
        let key = "\(Int(side))|\(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let masterKey = Session.shared.masterKey else { return nil }
        let pixels = Int(side * scale)
        let image: UIImage? = await Task.detached {
            if VaultItem(url: url).isVideo {
                let (asset, loader) = makeAsset(for: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: pixels, height: pixels)
                let frame = try? await generator.image(at: .zero).image
                withExtendedLifetime(loader) {}
                return frame.map { UIImage(cgImage: $0) }
            }
            guard let data = try? VaultCrypto.decryptAll(url, key: masterKey) else { return nil }
            return VaultCrypto.decodeImage(data, maxPixelSize: pixels)
        }.value
        // A decrypt can finish after the lock. Do not put its image back into the empty cache.
        if let image, Session.shared.masterKey != nil { cache.setObject(image, forKey: key) }
        return image
    }
}

/// Encrypts a picked photo or video into the vault directory. The app writes no plaintext copy.
struct ImportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try Self(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try Self(copying: $0.file) }
    }

    init(copying source: URL) throws {
        guard let key = Session.shared.masterKey else { throw VaultCrypto.Failure.locked }
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        let dest = vaultDirectory.appending(path: name).appendingPathExtension(source.pathExtension)
        try VaultCrypto.encrypt(from: source, to: dest, key: key)
        url = dest
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
