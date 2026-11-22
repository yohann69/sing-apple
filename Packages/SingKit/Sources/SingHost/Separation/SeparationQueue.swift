import Foundation
import SingCore

/// Shared with the audio-safe progress callback: lets a running separation wait while someone sings.
final class SeparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _holdBackground = false
    private var _holdAll = false
    var holdBackground: Bool {
        get { lock.withLock { _holdBackground } }
        set { lock.withLock { _holdBackground = newValue } }
    }
    var holdAll: Bool {
        get { lock.withLock { _holdAll } }
        set { lock.withLock { _holdAll = newValue } }
    }

    /// Blocks the worker thread (never the UI) for as long as this kind of work should wait.
    func waitIfNeeded(urgent: Bool) {
        while holdAll || (!urgent && holdBackground) { Thread.sleep(forTimeInterval: 0.25) }
    }
}

/// Reports progress at most twice a second, so the interface is not redrawn for every chunk.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private var lastAt = Date.distantPast
    func shouldSend(_ p: Double) -> Bool {
        lock.withLock {
            guard p - last >= 0.02 || Date.now.timeIntervalSince(lastAt) >= 0.5 || p >= 1 else { return false }
            last = p
            lastAt = .now
            return true
        }
    }
}

/// Serial background queue: songs in the play queue go first, the rest of the library after.
/// Work runs at background priority and on the CPU and Neural Engine only, leaving the GPU to the interface and the TV.
public actor SeparationQueue {
    public typealias ProgressHandler = @Sendable (SongID, Double, Readiness) -> Void

    let library: LibraryStore
    let paths: SingPaths
    let modelURL: URL
    var separator: DemucsSeparator?
    nonisolated let gate = SeparationGate()
    var currentIsUrgent = false
    var urgent: [SongID] = []
    var background: [SongID] = []
    var running = false
    var current: SongID?
    var paused = false
    /// Queued songs still run; the rest of the library waits.
    var holdBackground = false
    var onProgress: ProgressHandler?
    /// Lyrics, AI timing, pitch and singer detection; a song is only Ready once this has run.
    var postProcess: (@Sendable (SongID) async -> Void)?

    public func setPostProcess(_ p: @escaping @Sendable (SongID) async -> Void) { postProcess = p }

    public init(library: LibraryStore, paths: SingPaths, modelURL: URL) {
        self.library = library
        self.paths = paths
        self.modelURL = modelURL
    }

    public func setProgressHandler(_ h: @escaping ProgressHandler) { onProgress = h }

    public func setPaused(_ p: Bool) {
        paused = p
        if !p { kick() }
    }

    public func setHoldBackground(_ h: Bool) {
        holdBackground = h
        gate.holdBackground = h
        if !h { kick() }
    }

    /// Pauses even songs in the queue, mid-way; used while singing when the next song is already ready.
    public func setHoldAll(_ h: Bool) {
        gate.holdAll = h
    }

    public var modelAvailable: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    public func isReady(_ song: SongRecord) -> Bool {
        FileManager.default.fileExists(atPath: paths.vocals(song.audioHash).path)
            && FileManager.default.fileExists(atPath: paths.instrumental(song.audioHash).path)
    }

    public func prioritize(_ id: SongID) {
        guard id != current else { return }
        background.removeAll { $0 == id }
        urgent.removeAll { $0 == id }
        urgent.append(id)
        onProgress?(id, 0, .queuedForProcessing)
        kick()
    }

    public func enqueueBackground(_ ids: [SongID]) {
        for id in ids where id != current && !urgent.contains(id) && !background.contains(id) {
            background.append(id)
        }
        kick()
    }

    private func kick() {
        guard !running, !paused, !urgent.isEmpty || (!background.isEmpty && !holdBackground) else { return }
        running = true
        Task(priority: .background) { await self.loop() }
    }

    private func next() -> SongID? {
        if !urgent.isEmpty { currentIsUrgent = true; return urgent.removeFirst() }
        if !background.isEmpty, !holdBackground { currentIsUrgent = false; return background.removeFirst() }
        return nil
    }

    private func loop() async {
        while !paused, let id = next() {
            current = id
            await process(id)
            current = nil
        }
        running = false
    }

    private func process(_ id: SongID) async {
        guard let song = try? await library.song(id) else { return }
        if isReady(song) {
            if song.readiness != .ready {
                onProgress?(id, 0.7, .processing)
                await postProcess?(id)
                try? await library.update(id) { $0.readiness = .ready }
            }
            onProgress?(id, 1, .ready)
            return
        }
        try? await library.update(id) { $0.readiness = .processing }
        onProgress?(id, 0, .processing)
        do {
            if separator == nil { separator = try DemucsSeparator(modelURL: modelURL, computeUnits: .cpuAndNeuralEngine) }
            guard let separator else { return }
            let handler = onProgress
            let gate = self.gate, urgentNow = currentIsUrgent
            let throttle = ProgressThrottle()
            gate.waitIfNeeded(urgent: urgentNow)
            let audio = try StereoAudio.load(URL(fileURLWithPath: song.filePath))
            let vocals = try separator.separateVocals(audio) { p in
                gate.waitIfNeeded(urgent: urgentNow)
                if throttle.shouldSend(p) { handler?(id, p * 0.7, .processing) }
                return true
            }
            let instrumental = StereoAudio(
                left: zip(audio.left, vocals.left).map { $0 - $1 },
                right: zip(audio.right, vocals.right).map { $0 - $1 },
                sampleRate: audio.sampleRate
            )
            try FileManager.default.createDirectory(at: paths.songCache(song.audioHash), withIntermediateDirectories: true)
            try vocals.write(to: paths.vocals(song.audioHash))
            try instrumental.write(to: paths.instrumental(song.audioHash))
            onProgress?(id, 0.7, .processing)
            await postProcess?(id)
            try await library.update(id) { $0.readiness = .ready }
            onProgress?(id, 1, .ready)
        } catch {
            try? await library.update(id) { $0.readiness = .failed }
            onProgress?(id, 0, .failed)
        }
    }
}
