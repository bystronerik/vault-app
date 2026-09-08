import PhotosUI
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Application Support/Vault. The directory and every file in it use NSFileProtectionComplete.
let vaultDirectory: URL = {
    let dir = URL.applicationSupportDirectory.appending(path: "Vault")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.protectionKey: FileProtectionType.complete])
    return dir
}()

struct VaultItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var isVideo: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false }
}

/// The directory listing is the model. File names sort in import order.
@MainActor @Observable final class VaultStore {
    private(set) var items: [VaultItem] = []
    private static let cache = NSCache<NSString, UIImage>()

    init() { reload() }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: vaultDirectory, includingPropertiesForKeys: nil,
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

    /// A downscaled image for photos and a poster frame for videos. `side` is in points.
    // ponytail: memory cache only, so every unlock regenerates thumbnails. Cache to disk if the grid feels slow with hundreds of items.
    static func image(for url: URL, side: CGFloat, scale: CGFloat) async -> UIImage? {
        let key = "\(Int(side))|\(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Copies a picked photo or video into the vault directory. Keeps the original file bytes.
struct ImportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try Self(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try Self(copying: $0.file) }
    }

    init(copying source: URL) throws {
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        let dest = vaultDirectory.appending(path: name).appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dest.path)
        url = dest
    }
}
