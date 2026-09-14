import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CalculatorVault

/// The key of all test files.
private let key = SymmetricKey(size: .bits256)
/// All test files except the source videos and the thumbnail files. The tests never use `vaultDirectory`.
let root = URL.temporaryDirectory.appending(path: "VaultPerformanceTests")
/// The plaintext source videos. They stay after the tests, because the simulator needs minutes to make them.
private let videoCache = URL.cachesDirectory.appending(path: "VaultPerformanceTests")
/// The test sizes use 1 MB = 1 000 000 bytes.
let megabyte = 1_000_000
/// A guard: the full pass stops at 4 GB, half the memory of an iPhone 17, so that a memory problem does not fill the
/// memory of the Mac. Before the cache limit and the thumbnail files, a full pass of 10 000 photos needed about 30 GB.
private let memoryLimit: UInt64 = 4_000_000_000

/// The physical footprint of the app.
private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Measures how fast the app opens and shows large vaults. The tests report numbers and have no pass or fail limits.
@MainActor final class VaultPerformanceTests: XCTestCase {
    private static var photos: [URL] = []

    override nonisolated static func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override nonisolated static func tearDown() {
        for path in FileManager.default.subpaths(atPath: root.path) ?? [] {
            try? FileManager.default.removeItem(at: thumbnailURL(for: URL(filePath: path)))
        }
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    override nonisolated func setUp() {
        super.setUp()
        Session.shared.unlock(key)
        // `unlock` sets `unlocked`, and then the host app opens `VaultView`, which reads `vaultDirectory`.
        // The key stays set when `unlocked` is false, so the host app stays on its first screen.
        Session.shared.unlocked = false
        // Stops the inactivity lock.
        Session.shared.paused = true
    }

    override nonisolated func tearDown() {
        MainActor.assumeIsolated { VaultStore.cache.removeAllObjects() }
        super.tearDown()
    }

    // MARK: Images

    func testOpen1000() throws { try measureOpen(count: 1_000) }
    func testOpen2000() throws { try measureOpen(count: 2_000) }
    func testOpen10000() throws { try measureOpen(count: 10_000) }
    func testFirstScreen1000() throws { try measureFirstScreen(count: 1_000) }
    func testFirstScreen2000() throws { try measureFirstScreen(count: 2_000) }
    func testFirstScreen10000() throws { try measureFirstScreen(count: 10_000) }
    func testFullPass1000() throws { try measureFullPass(count: 1_000) }
    func testFullPass2000() throws { try measureFullPass(count: 2_000) }
    func testFullPass10000() throws { try measureFullPass(count: 10_000) }

    /// Open: `VaultStore` lists and sorts the files.
    private func measureOpen(count: Int) throws {
        let directory = try photoDirectory(count: count)
        var itemCount = 0
        measure(iterations: 5) {
            startMeasuring()
            itemCount = VaultStore(directory: directory).items.count
            stopMeasuring()
        }
        XCTAssertEqual(itemCount, count)
    }

    /// First screen: the thumbnails of the first 18 items at side 150 and scale 3, as `Thumbnail` on an iPhone 17.
    /// The 18 calls start at the same time, as the cells of the grid do.
    private func measureFirstScreen(count: Int) throws {
        let store = try autoreleasepool { try VaultStore(directory: photoDirectory(count: count)) }
        var result = (items: 0, failed: 0)
        measure(iterations: 5) {
            startMeasuring()
            result = thumbnailsAtOnce(store.items.prefix(18))
            stopMeasuring()
        }
        XCTAssertEqual(result.items, 18)
        XCTAssertEqual(result.failed, 0)
    }

    /// Full pass: the thumbnails of all items, one at a time, from the thumbnail files. This is a scroll to the end after an unlock.
    /// The pass stops at `memoryLimit`, and the test writes the number of items to the log.
    private func measureFullPass(count: Int) throws {
        let store = try autoreleasepool { try VaultStore(directory: photoDirectory(count: count)) }
        var runs = 0, result = (items: 0, failed: 0)
        measure(iterations: 3) {
            runs += 1
            // XCTest discards the first run. A full pass takes minutes, so the first run only warms up with 18 items.
            let items = runs == 1 ? store.items.prefix(18) : store.items[...]
            startMeasuring()
            result = thumbnails(items)
            stopMeasuring()
        }
        print("VaultPerformanceTests: The full pass of \(count) items made \(result.items) thumbnails in the last run.")
        XCTAssertEqual(result.failed, 0)
    }

    /// Makes the grid thumbnails of `items` one at a time. Stops when the app uses more memory than `memoryLimit`.
    private func thumbnails(_ items: ArraySlice<VaultItem>) -> (items: Int, failed: Int) {
        run {
            var result = (items: 0, failed: 0)
            for item in items {
                if await VaultStore.thumbnail(for: item) == nil { result.failed += 1 }
                result.items += 1
                if footprint() > memoryLimit { break }
            }
            return result
        }
    }

    // MARK: Videos

    func testImport100MB() throws { try measureImport(megabytes: 100) }
    func testImport500MB() throws { try measureImport(megabytes: 500) }
    func testImport1000MB() throws { try measureImport(megabytes: 1_000) }
    func testGridThumbnail100MB() throws { try measureGridThumbnail(megabytes: 100) }
    func testGridThumbnail500MB() throws { try measureGridThumbnail(megabytes: 500) }
    func testGridThumbnail1000MB() throws { try measureGridThumbnail(megabytes: 1_000) }
    func testPlaybackStart100MB() throws { try measurePlaybackStart(megabytes: 100) }
    func testPlaybackStart500MB() throws { try measurePlaybackStart(megabytes: 500) }
    func testPlaybackStart1000MB() throws { try measurePlaybackStart(megabytes: 1_000) }
    func testSeek100MB() throws { try measureSeek(megabytes: 100) }
    func testSeek500MB() throws { try measureSeek(megabytes: 500) }
    func testSeek1000MB() throws { try measureSeek(megabytes: 1_000) }

    /// Import: `VaultCrypto.encrypt(from:to:key:)`, as `ImportedFile` calls it. MB/s is the size divided by the time.
    private func measureImport(megabytes: Int) throws {
        let source = try sourceVideo(megabytes: megabytes)
        let destination = sealedVideoURL(megabytes: megabytes)
        measure(iterations: 5) {
            // `encrypt` fails when the destination exists.
            try? FileManager.default.removeItem(at: destination)
            startMeasuring()
            do { try VaultCrypto.encrypt(from: source, to: destination, key: key) } catch { XCTFail("\(error)") }
            stopMeasuring()
        }
    }

    /// Grid thumbnail: `VaultStore.thumbnail(for:)` reads the first frame through `VaultResourceLoader` and writes the
    /// thumbnail file. Each run deletes the thumbnail file first, so the test measures the first time.
    private func measureGridThumbnail(megabytes: Int) throws {
        let item = try sealedVideo(megabytes: megabytes)
        var loaded = false
        measure(iterations: 5) {
            try? FileManager.default.removeItem(at: thumbnailURL(for: item.url))
            startMeasuring()
            loaded = run { await VaultStore.thumbnail(for: item) != nil }
            stopMeasuring()
        }
        XCTAssertTrue(loaded)
    }

    /// Playback start: from a new player until the item is ready to play.
    private func measurePlaybackStart(megabytes: Int) throws {
        let item = try sealedVideo(megabytes: megabytes)
        measure(iterations: 5) {
            startMeasuring()
            let opened = openPlayer(item)
            stopMeasuring()
            close(opened)
        }
    }

    /// Seek: a seek to 90 % of the duration, right after the item is ready to play, until the seek completes.
    private func measureSeek(megabytes: Int) throws {
        let item = try sealedVideo(megabytes: megabytes)
        measure(iterations: 5) {
            let opened = openPlayer(item)
            let time = CMTimeMultiplyByFloat64(opened.player.currentItem!.duration, multiplier: 0.9)
            let done = expectation(description: "seek")
            startMeasuring()
            opened.player.seek(to: time) { finished in
                XCTAssertTrue(finished)
                done.fulfill()
            }
            wait(for: [done], timeout: 600)
            stopMeasuring()
            close(opened)
        }
    }

    // MARK: Helpers

    /// Measures the time and the peak memory in `iterations` runs. XCTest runs the block one more time first and discards
    /// that run. The block calls `startMeasuring` and `stopMeasuring`, so that its setup is not in the numbers.
    private func measure(iterations: Int, _ block: () -> Void) {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            // Each unlock starts with an empty cache.
            VaultStore.cache.removeAllObjects()
            block()
        }
    }

    /// Runs `body` on the main actor, as a view task does, and waits until it completes.
    private func run<T>(_ body: @escaping @MainActor () async -> T) -> T {
        var result: T?
        let done = expectation(description: "done")
        Task {
            result = await body()
            done.fulfill()
        }
        wait(for: [done], timeout: 3_600)
        return result!
    }

    /// Makes an `AVPlayer` with an `AVPlayerItem` on `makeAsset(for:)`, as `VideoPage` does, and waits until the item is
    /// ready to play. Keep the loader until `close`.
    private func openPlayer(_ video: VaultItem) -> (player: AVPlayer, loader: VaultResourceLoader) {
        let (asset, loader) = makeAsset(for: video)
        let item = AVPlayerItem(asset: asset)
        // `VideoPlayer` shows the frames. Without a video output, a seek completes before AVFoundation loads any data.
        item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        let ready = expectation(description: "ready to play")
        ready.assertForOverFulfill = false
        let observation = item.observe(\.status, options: .initial) { item, _ in
            if item.status != .unknown { ready.fulfill() }
        }
        wait(for: [ready], timeout: 600)
        observation.invalidate()
        XCTAssertEqual(item.status, .readyToPlay, String(describing: item.error))
        return (player, loader)
    }

    /// Removes the item and waits for the callbacks on the loader queue. The loader serves the requests on another queue,
    /// and a cancelled request stops within one chunk.
    private func close(_ opened: (player: AVPlayer, loader: VaultResourceLoader)) {
        withExtendedLifetime(opened.loader) {
            let queue = (opened.player.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegateQueue
            opened.player.replaceCurrentItem(with: nil)
            queue?.sync {}
        }
    }

    /// A directory with `count` encrypted photos and their thumbnail files. The files are copies of 10 photos, with names
    /// in the format of `ImportedFile`. On APFS, `copyItem` makes clones, so the copies use almost no disk space.
    private func photoDirectory(count: Int) throws -> URL {
        let directory = root.appending(path: "photos-\(count)")
        if FileManager.default.fileExists(atPath: directory.path) { return directory }
        // The pool releases the memory of the setup before the measurement starts.
        try autoreleasepool {
            let photos = try sealedPhotos()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<count {
                let photo = photos[index % photos.count]
                let name = "\(1_757_800_000_000 + index)-\(UUID().uuidString.prefix(8)).\(photo.pathExtension)"
                try FileManager.default.copyItem(at: photo, to: directory.appending(path: name))
                try FileManager.default.copyItem(at: thumbnailURL(for: photo), to: thumbnailURL(for: directory.appending(path: name)))
            }
        }
        return directory
    }

    /// 10 different 12 MP photos of 2 to 4 MB, each encrypted once with `VaultCrypto.encrypt`, and their thumbnail files.
    private func sealedPhotos() throws -> [URL] {
        guard Self.photos.isEmpty else { return Self.photos }
        let type = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier) ? UTType.heic : .jpeg
        if type != .heic { print("VaultPerformanceTests: This destination cannot encode HEIC. The photos are JPEG.") }
        let directory = root.appending(path: "photos")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<10 {
            let data = try XCTUnwrap(encode(makePhoto(seed: UInt64(index)), as: type))
            XCTAssert((2 * megabyte...4 * megabyte).contains(data.count), "The photo has \(data.count) bytes.")
            let plain = directory.appending(path: "plain-\(index).\(type.preferredFilenameExtension!)")
            let sealed = directory.appending(path: "\(index).\(type.preferredFilenameExtension!)")
            try data.write(to: plain)
            try VaultCrypto.encrypt(from: plain, to: sealed, key: key)
            XCTAssertNotNil(run { await VaultStore.thumbnail(for: VaultItem(url: sealed, type: type)) })
            Self.photos.append(sealed)
        }
        return Self.photos
    }

    /// The plaintext source video. If it is not in the cache, the test makes it first.
    private func sourceVideo(megabytes: Int) throws -> URL {
        let url = videoCache.appending(path: "video-\(megabytes)MB.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: videoCache, withIntermediateDirectories: true)
            try autoreleasepool { try writeVideo(megabytes: megabytes, to: url) }
        }
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(Double(size), Double(megabytes * megabyte), accuracy: 0.05 * Double(megabytes * megabyte))
        return url
    }

    private func sealedVideoURL(megabytes: Int) -> URL { root.appending(path: "video-\(megabytes)MB.mov") }

    /// The encrypted source video. `measureImport` writes the same file.
    private func sealedVideo(megabytes: Int) throws -> VaultItem {
        let url = sealedVideoURL(megabytes: megabytes)
        if !FileManager.default.fileExists(atPath: url.path) {
            try autoreleasepool { try VaultCrypto.encrypt(from: sourceVideo(megabytes: megabytes), to: url, key: key) }
        }
        return VaultItem(url: url, type: .quickTimeMovie)
    }
}

extension VaultPerformanceTests {
    /// The first scroll after the update: 200 items with no thumbnail files. The calls start at the same time.
    /// Each run deletes the thumbnail files first. The peak memory shows if the cache keeps decrypted photos.
    func testNoThumbnails1000() throws {
        let store = try autoreleasepool { try VaultStore(directory: photoDirectory(count: 1_000)) }
        let items = store.items.prefix(200)
        var result = (items: 0, failed: 0)
        measure(iterations: 3) {
            for item in items { try? FileManager.default.removeItem(at: thumbnailURL(for: item.url)) }
            startMeasuring()
            result = thumbnailsAtOnce(items)
            stopMeasuring()
        }
        XCTAssertEqual(result.items, 200)
        XCTAssertEqual(result.failed, 0)
    }

    /// Makes the grid thumbnails of `items` with calls that start at the same time.
    private func thumbnailsAtOnce(_ items: ArraySlice<VaultItem>) -> (items: Int, failed: Int) {
        run {
            await withTaskGroup(of: Bool.self) { group in
                for item in items {
                    group.addTask { await VaultStore.thumbnail(for: item) != nil }
                }
                var result = (items: 0, failed: 0)
                for await loaded in group {
                    result.items += 1
                    if !loaded { result.failed += 1 }
                }
                return result
            }
        }
    }

    /// The loader serves the same video samples as the plaintext file. A loader that gives short data can still reach
    /// "ready to play".
    func testLoaderReadsAllSamples() async throws {
        let (asset, loader) = try makeAsset(for: sealedVideo(megabytes: 100))
        let sealed = try await samples(of: asset)
        withExtendedLifetime(loader) {}
        let plain = try await samples(of: AVURLAsset(url: sourceVideo(megabytes: 100)))
        XCTAssertGreaterThan(plain.count, 0)
        XCTAssertEqual(sealed.count, plain.count)
        XCTAssertEqual(sealed.digest, plain.digest)
    }

    /// Reads all video samples of `asset` with `AVAssetReader`. Returns their number and the SHA-256 of their bytes.
    private func samples(of asset: AVAsset) async throws -> (count: Int, digest: SHA256Digest) {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        XCTAssertTrue(reader.startReading(), String(describing: reader.error))
        var count = 0, hash = SHA256()
        // The reader can also give marker buffers with no data.
        while let buffer = output.copyNextSampleBuffer() {
            guard let data = buffer.dataBuffer else { continue }
            count += buffer.numSamples
            try hash.update(data: data.dataBytes())
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        return (count, hash.finalize())
    }
}
