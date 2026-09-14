import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CalculatorVault

/// The key of all test files.
private let key = SymmetricKey(size: .bits256)
/// All test files except the source videos. The tests never use `vaultDirectory`.
private let root = URL.temporaryDirectory.appending(path: "VaultPerformanceTests")
/// The plaintext source videos. They stay after the tests, because the simulator needs minutes to make them.
private let videoCache = URL.cachesDirectory.appending(path: "VaultPerformanceTests")
/// The test sizes use 1 MB = 1 000 000 bytes.
private let megabyte = 1_000_000
/// Each cached thumbnail keeps its whole decrypted photo, so a full pass of 10 000 photos needs about 30 GB.
/// The full pass stops at 4 GB, half the memory of an iPhone 17, so that the test does not fill the memory of the Mac.
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
    /// The calls run one at a time. When the 18 calls run at the same time, the HEIC decoder blocks all threads of the
    /// Swift concurrency pool on the simulator, and no call completes.
    private func measureFirstScreen(count: Int) throws {
        let store = try autoreleasepool { try VaultStore(directory: photoDirectory(count: count)) }
        var result = (items: 0, failed: 0)
        measure(iterations: 5) {
            startMeasuring()
            result = thumbnails(store.items.prefix(18))
            stopMeasuring()
        }
        XCTAssertEqual(result.items, 18)
        XCTAssertEqual(result.failed, 0)
    }

    /// Full pass: the thumbnails of all items, one at a time. This is the worst case: a scroll to the end after an unlock.
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
                if await VaultStore.image(for: item.url, side: 150, scale: 3) == nil { result.failed += 1 }
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

    /// Grid thumbnail: `VaultStore.image(for:side:scale:)` reads the first frame through `VaultResourceLoader`.
    private func measureGridThumbnail(megabytes: Int) throws {
        let url = try sealedVideo(megabytes: megabytes)
        var loaded = false
        measure(iterations: 5) {
            startMeasuring()
            loaded = run { await VaultStore.image(for: url, side: 150, scale: 3) != nil }
            stopMeasuring()
        }
        XCTAssertTrue(loaded)
    }

    /// Playback start: from a new player until the item is ready to play.
    private func measurePlaybackStart(megabytes: Int) throws {
        let url = try sealedVideo(megabytes: megabytes)
        measure(iterations: 5) {
            startMeasuring()
            let opened = openPlayer(url)
            stopMeasuring()
            close(opened)
        }
    }

    /// Seek: a seek to 90 % of the duration, right after the item is ready to play, until the seek completes.
    private func measureSeek(megabytes: Int) throws {
        let url = try sealedVideo(megabytes: megabytes)
        measure(iterations: 5) {
            let opened = openPlayer(url)
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
    private func openPlayer(_ url: URL) -> (player: AVPlayer, loader: VaultResourceLoader) {
        let (asset, loader) = makeAsset(for: url)
        let item = AVPlayerItem(asset: asset)
        // `VideoPlayer` shows the frames. Without a video output, a seek completes before AVFoundation loads any data.
        item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))
        let player = AVPlayer(playerItem: item)
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

    /// Removes the item and waits until the loader queue is idle, so that the next run does not share the CPU with it.
    private func close(_ opened: (player: AVPlayer, loader: VaultResourceLoader)) {
        withExtendedLifetime(opened.loader) {
            let queue = (opened.player.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegateQueue
            opened.player.replaceCurrentItem(with: nil)
            queue?.sync {}
        }
    }

    /// A directory with `count` encrypted photos. The files are copies of 10 photos, with names in the format of
    /// `ImportedFile`. On APFS, `copyItem` makes clones, so the copies use almost no disk space.
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
            }
        }
        return directory
    }

    /// 10 different 12 MP photos of 2 to 4 MB, each encrypted once with `VaultCrypto.encrypt`.
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
    private func sealedVideo(megabytes: Int) throws -> URL {
        let url = sealedVideoURL(megabytes: megabytes)
        if !FileManager.default.fileExists(atPath: url.path) {
            try autoreleasepool { try VaultCrypto.encrypt(from: sourceVideo(megabytes: megabytes), to: url, key: key) }
        }
        return url
    }
}

// MARK: Test data

/// SplitMix64. A fixed seed gives the same test files in each run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Writes random bytes, 8 at a time. `mask` sets the range around 128: 0xFF for all values, 0x0F for 16 values.
/// The last `count % 8` bytes do not change.
private func fillNoise(_ base: UnsafeMutableRawPointer, count: Int, mask: UInt8, using random: inout SplitMix64) {
    let bits = UInt64(mask) &* 0x0101_0101_0101_0101
    let low = UInt64(128 - (Int(mask) + 1) / 2) &* 0x0101_0101_0101_0101
    for offset in stride(from: 0, to: count - 7, by: 8) {
        base.storeBytes(of: (random.next() & bits) &+ low, toByteOffset: offset, as: UInt64.self)
    }
}

private func bitmap(width: Int, height: Int, gray: Bool) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
}

private func noise(width: Int, height: Int, gray: Bool, using random: inout SplitMix64) -> CGImage {
    let context = bitmap(width: width, height: height, gray: gray)
    fillNoise(context.data!, count: context.bytesPerRow * height, mask: 0xFF, using: &random)
    return context.makeImage()!
}

/// A 4000 x 3000 picture with the structure of a photo: soft color areas, texture at different scales, edges, and grain.
private func makePhoto(seed: UInt64) -> CGImage {
    var random = SplitMix64(state: seed)
    func value(_ range: ClosedRange<CGFloat>) -> CGFloat { .random(in: range, using: &random) }
    let frame = CGRect(x: 0, y: 0, width: 4_000, height: 3_000)
    let context = bitmap(width: 4_000, height: 3_000, gray: false)
    context.interpolationQuality = .high
    // Noise at a low resolution, scaled up, makes soft areas. Each finer layer adds texture.
    // swiftlint:disable:next large_tuple
    let layers: [(width: Int, height: Int, alpha: CGFloat)] = [(6, 4, 1), (24, 18, 0.35), (100, 75, 0.25), (400, 300, 0.18), (1_600, 1_200, 0.12)]
    for (index, layer) in layers.enumerated() {
        context.setAlpha(layer.alpha)
        context.draw(noise(width: layer.width, height: layer.height, gray: index > 1, using: &random), in: frame)
    }
    context.setAlpha(1)
    for _ in 0..<60 {
        context.setFillColor(red: value(0...1), green: value(0...1), blue: value(0...1), alpha: value(0.3...0.8))
        let rect = CGRect(x: value(0...4_000), y: value(0...3_000), width: value(100...1_000), height: value(100...1_000))
        if Bool.random(using: &random) { context.fillEllipse(in: rect) } else { context.fill(rect) }
    }
    context.setAlpha(0.08)
    context.draw(noise(width: 4_000, height: 3_000, gray: true, using: &random), in: frame)
    return context.makeImage()!
}

private func encode(_ image: CGImage, as type: UTType) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

/// Writes `megabytes` MB of H.264 video, 3840 x 2160 at 30 fps and 50 Mbit/s, with the `moov` atom at the end of the file.
/// The frames are noise, so the encoder uses the full bit rate. The file goes to `url` only when it is complete.
private func writeVideo(megabytes: Int, to url: URL) throws {
    let bitRate = 50_000_000
    let part = root.appending(path: url.lastPathComponent)
    try? FileManager.default.removeItem(at: part)
    let writer = try AVAssetWriter(outputURL: part, fileType: .mov)
    writer.shouldOptimizeForNetworkUse = false
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 3_840, AVVideoHeightKey: 2_160,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate, AVVideoExpectedSourceFrameRateKey: 30,
                                          AVVideoMaxKeyFrameIntervalKey: 30, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: 3_840, kCVPixelBufferHeightKey as String: 2_160,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    // Full-range noise needs more bits than 50 Mbit/s at the highest quantizer. Noise with 16 values fits the bit rate.
    var random = SplitMix64(state: UInt64(megabytes))
    for frame in 0..<(megabytes * megabyte * 8 / bitRate * 30) {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        var pixels: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixels)
        let buffer = pixels!
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            fillNoise(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!,
                      count: CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane),
                      mask: 0x0F, using: &random)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else { break }
    }
    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    finished.wait()
    guard writer.status == .completed else { throw writer.error! }
    try FileManager.default.moveItem(at: part, to: url)
}
