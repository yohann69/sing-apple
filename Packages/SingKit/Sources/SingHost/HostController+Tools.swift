#if os(macOS)
import AVFoundation
import Foundation
import SingCore

public struct InstalledModel: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var task: String
    public var bytes: Int64
    public var bundled: Bool
}

/// Model manager, cache location and the clap test.
extension HostController {

    // MARK: Models

    static let modelTasks = ["htdemucs": "Vocal separation", "crepe_full": "Melody (pitch guide and score)", "ecapa": "Singer detection"]

    public func installedModels() -> [InstalledModel] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: paths.models, includingPropertiesForKeys: nil)) ?? []
        return items.filter { ["mlmodelc", "mlpackage"].contains($0.pathExtension) }.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            return InstalledModel(name: name, task: Self.modelTasks[name] ?? "Other", bytes: Self.size(of: url).bytes,
                                  bundled: Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil)
        }.sorted { $0.name < $1.name }
    }

    public func modelList() async -> [ModelInfo] { installedModels().map { ModelInfo(name: $0.name, task: $0.task, bytes: $0.bytes) } }

    public func removeModel(_ name: String) {
        for ext in ["mlmodelc", "mlpackage"] { try? FileManager.default.removeItem(at: paths.models.appendingPathComponent("\(name).\(ext)")) }
        audit("Mac", "removed the \(name) model")
    }

    /// Copies the models shipped inside the app again, for example after removing a broken one.
    public func reinstallBundledModels() {
        Self.installBundledModels(into: paths.models)
        audit("Mac", "reinstalled the bundled models")
    }

    // MARK: Cache location

    /// Moves every song cache to another folder (an external drive), checks the copy, then switches.
    public func moveCache(to folder: URL) async throws {
        let dest = folder.appendingPathComponent("Sing Cache", isDirectory: true)
        let src = paths.cache
        guard dest.standardizedFileURL != src.standardizedFileURL else { return }
        let fm = FileManager.default
        try await Task.detached(priority: .utility) {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for item in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                let target = dest.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: item, to: target)
            }
            let a = HostController.size(of: src).bytes, b = HostController.size(of: dest).bytes
            guard b >= a else { throw ErrorBody(code: "verify", message: "The copy on the new disk is incomplete; nothing was moved.") }
            try? fm.removeItem(at: src)
        }.value
        UserDefaults.standard.set(dest, forKey: "cacheRoot")
        audit("Mac", "moved the song caches to \(folder.path)")
    }

    public var cacheLocation: URL { paths.cache }

    // MARK: Clap test

    /// Plays eight clicks; people clap along. The delay between each click and the clap the mic hears is the
    /// room's round-trip latency, used to line up scoring and recordings.
    public func clapTest() async throws -> Double {
        guard nowPlaying.state == .idle || nowPlaying.state == .finished else { throw ErrorBody(code: "busy", message: "Run the clap test between songs.") }
        guard mic.isRunning else { throw ErrorBody(code: "mic", message: "Turn the microphone on first.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sing-clicks.caf")
        let rate = 44100.0, count = 9
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * Double(count + 1)))!
        buf.frameLength = buf.frameCapacity
        for c in 0..<2 {
            let p = buf.floatChannelData![c]
            for i in 0..<Int(buf.frameLength) { p[i] = 0 }
            for k in 1...count {
                let start = Int(Double(k) * rate)
                for i in 0..<800 { p[start + i] = sin(Float(i) * 2 * .pi * 1500 / Float(rate)) * (1 - Float(i) / 800) * 0.8 }
            }
        }
        try file.write(from: buf)
        try playback.load(instrumental: url, vocals: nil)
        let t0 = Date.now
        try playback.play(from: 0)
        var samples: [(Double, Float)] = []
        while Date.now.timeIntervalSince(t0) < Double(count) + 1.3 {
            try? await Task.sleep(for: .milliseconds(4))
            samples.append((Date.now.timeIntervalSince(t0), mic.level))
        }
        playback.stop()
        let peak = samples.map(\.1).max() ?? 0
        guard peak > 0.05 else { throw ErrorBody(code: "quiet", message: "No claps were heard. Clap louder, close to the mic.") }
        var delays: [Double] = []
        for k in 2...count {
            let click = Double(k) + 0.05
            if let hit = samples.first(where: { $0.0 > click - 0.25 && $0.0 < click + 0.6 && $0.1 > peak * 0.45 }) { delays.append(hit.0 - click) }
        }
        guard delays.count >= 4 else { throw ErrorBody(code: "unsteady", message: "Not enough claps on the beat. Try again, clapping with each click.") }
        let median = delays.sorted()[delays.count / 2]
        let ms = max(0, min(600, median * 1000))
        settings.playback.roundTripLatencyMs = ms
        return ms
    }

    /// Extra mic delay beyond what the output already accounts for.
    var micLag: Double { max(0, settings.playback.roundTripLatencyMs / 1000 - playback.outputLatency) }
}
#endif
