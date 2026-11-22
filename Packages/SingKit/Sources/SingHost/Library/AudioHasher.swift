import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import CoreGraphics

public enum AudioHasher {
    /// SHA-256 of the decoded first channel, so re-tagged, renamed or moved files keep their cache.
    public static func hash(_ url: URL) throws -> String {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw CocoaError(.fileReadUnknown)
        }
        var hasher = SHA256()
        withUnsafeBytes(of: file.processingFormat.sampleRate) { hasher.update(bufferPointer: $0) }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0, let ch = buffer.floatChannelData?[0] else { break }
            var quantized = [Int16](repeating: 0, count: Int(buffer.frameLength))
            for i in 0..<Int(buffer.frameLength) {
                quantized[i] = Int16(max(-1, min(1, ch[i])) * 32767)
            }
            quantized.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum PaletteExtractor {
    /// Up to four vivid, distinct colors from artwork, as hex strings.
    public static func palette(from data: Data, count: Int = 4) -> [String] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48] as CFDictionary)
        else { return [] }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        struct Bucket { var r = 0.0, g = 0.0, b = 0.0, n = 0.0 }
        var buckets: [Int: Bucket] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let key = Int(r * 5) * 36 + Int(g * 5) * 6 + Int(b * 5)
            var bk = buckets[key, default: Bucket()]
            bk.r += r; bk.g += g; bk.b += b; bk.n += 1
            buckets[key] = bk
        }
        let colors: [(r: Double, g: Double, b: Double, score: Double)] = buckets.values.map { bk in
            let r = bk.r / bk.n, g = bk.g / bk.n, b = bk.b / bk.n
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            let lightPenalty = mx < 0.18 ? 0.25 : (mn > 0.9 ? 0.4 : 1)
            return (r, g, b, bk.n * (0.25 + sat) * lightPenalty)
        }.sorted { $0.score > $1.score }

        var picked: [(Double, Double, Double)] = []
        for c in colors {
            if picked.allSatisfy({ abs($0.0 - c.r) + abs($0.1 - c.g) + abs($0.2 - c.b) > 0.35 }) {
                picked.append((c.r, c.g, c.b))
            }
            if picked.count == count { break }
        }
        while picked.count < count, let first = picked.first {
            picked.append((first.0 * 0.6, first.1 * 0.6, first.2 * 0.6))
        }
        return picked.map { String(format: "#%02X%02X%02X", Int($0.0 * 255), Int($0.1 * 255), Int($0.2 * 255)) }
    }
}

public struct SingPaths: Sendable {
    public let root: URL
    /// Song caches on another disk, chosen in Settings, Storage.
    public var cacheOverride: URL?

    public init(root: URL) { self.root = root }

    public static var `default`: SingPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var p = SingPaths(root: base.appendingPathComponent("Sing", isDirectory: true))
        p.cacheOverride = UserDefaults.standard.url(forKey: "cacheRoot")
        return p
    }

    public var database: URL { root.appendingPathComponent("sing.sqlite") }
    public var cache: URL { cacheOverride ?? root.appendingPathComponent("Cache", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }

    public func songCache(_ hash: String) -> URL {
        cache.appendingPathComponent(hash, isDirectory: true)
    }

    public func artwork(_ hash: String) -> URL { songCache(hash).appendingPathComponent("artwork.jpg") }
    public func vocals(_ hash: String) -> URL { songCache(hash).appendingPathComponent("vocals.caf") }
    public func instrumental(_ hash: String) -> URL { songCache(hash).appendingPathComponent("instrumental.caf") }
    public func lyrics(_ hash: String) -> URL { songCache(hash).appendingPathComponent("lyrics.json") }
    public func pitch(_ hash: String) -> URL { songCache(hash).appendingPathComponent("pitch.json") }

    public func ensure() throws {
        for dir in [root, cache, models, recordings] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
