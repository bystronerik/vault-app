import AVFoundation
import UniformTypeIdentifiers

/// Serves decrypted byte ranges of one vault file to AVFoundation. The caller keeps the loader alive.
final class VaultResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let url: URL

    init(url: URL) { self.url = url }

    func resourceLoader(_: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        do {
            guard let key = Session.shared.masterKey else { throw VaultCrypto.Failure.locked }
            let total = try VaultCrypto.plaintextLength(url)
            if let info = request.contentInformationRequest {
                info.contentType = UTType(filenameExtension: url.pathExtension)?.identifier
                info.contentLength = Int64(total)
                info.isByteRangeAccessSupported = true
            }
            if let data = request.dataRequest {
                let start = UInt64(data.requestedOffset)
                let end = data.requestsAllDataToEndOfResource ? total : min(total, start + UInt64(data.requestedLength))
                try VaultCrypto.decrypt(url, key: key, range: start..<end) {
                    guard !request.isCancelled else { throw CancellationError() }
                    data.respond(with: $0)
                }
            }
            request.finishLoading()
        } catch {
            if !request.isCancelled { request.finishLoading(with: error) }
        }
        return true
    }
}

/// An asset that reads the vault file through the loader. Keep the loader alive while the asset is in use.
func makeAsset(for url: URL) -> (AVURLAsset, VaultResourceLoader) {
    let loader = VaultResourceLoader(url: url)
    let asset = AVURLAsset(url: URL(string: "cvlt://vault/\(url.lastPathComponent)")!)
    asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "vault.loader"))
    return (asset, loader)
}
