import AVFoundation
import UniformTypeIdentifiers

/// Serves decrypted byte ranges of one vault file to AVFoundation. The caller keeps the loader alive.
final class VaultResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let item: VaultItem

    init(item: VaultItem) { self.item = item }

    func resourceLoader(_: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        // Serve off the delegate queue, so AVFoundation can send the next request and cancel this one.
        DispatchQueue.global(qos: .userInitiated).async { self.serve(request) }
        return true
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) {
        do {
            guard let key = Session.shared.masterKey else { throw VaultCrypto.Failure.locked }
            let total = try VaultCrypto.plaintextLength(item.url)
            if let info = request.contentInformationRequest {
                info.contentType = item.type.identifier
                info.contentLength = Int64(total)
                info.isByteRangeAccessSupported = true
            }
            if let data = request.dataRequest {
                let start = min(UInt64(data.requestedOffset), total)
                let end = data.requestsAllDataToEndOfResource ? total : min(total, start + UInt64(data.requestedLength))
                try VaultCrypto.decrypt(item.url, key: key, range: start..<end) {
                    guard !request.isCancelled else { throw CancellationError() }
                    // A long request stops at the lock.
                    guard Session.shared.masterKey != nil else { throw VaultCrypto.Failure.locked }
                    data.respond(with: $0)
                }
            }
            request.finishLoading()
        } catch {
            if !request.isCancelled { request.finishLoading(with: error) }
        }
    }
}

/// An asset that reads the vault file through the loader. Keep the loader alive while the asset is in use.
func makeAsset(for item: VaultItem) -> (AVURLAsset, VaultResourceLoader) {
    let loader = VaultResourceLoader(item: item)
    let asset = AVURLAsset(url: URL(string: "cvlt://vault/\(item.url.lastPathComponent)")!)
    asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "vault.loader"))
    return (asset, loader)
}
