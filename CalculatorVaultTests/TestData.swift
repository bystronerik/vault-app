import AVFoundation
import ImageIO
import UniformTypeIdentifiers

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
func makePhoto(seed: UInt64) -> CGImage {
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

func encode(_ image: CGImage, as type: UTType) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

/// Writes `megabytes` MB of H.264 video, 3840 x 2160 at 30 fps and 50 Mbit/s, with the `moov` atom at the end of the file.
/// The frames are noise, so the encoder uses the full bit rate. The file goes to `url` only when it is complete.
func writeVideo(megabytes: Int, to url: URL) throws {
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
