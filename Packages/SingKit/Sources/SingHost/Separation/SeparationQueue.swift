import Foundation
import SingCore

/// Serial background queue: songs in the play queue go first, the rest of the library after.
public actor SeparationQueue {
    public typealias ProgressHandler = @Sendable (SongID, Double, Readiness) -> Void

    let library: LibraryStore
    let paths: SingPaths
    let modelURL: URL
    var separator: DemucsSeparator?
    var urgent: [SongID] = []
    var background: [SongID] = []
    var running = false
    var current: SongID?
    var paused = false
    var onProgress: ProgressHandler?

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
        guard !running, !paused else { return }
        running = true
        Task { await self.loop() }
    }

    private func next() -> SongID? {
        if !urgent.isEmpty { return urgent.removeFirst() }
        if !background.isEmpty { return background.removeFirst() }
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
            try? await library.update(id) { $0.readiness = .ready }
            onProgress?(id, 1, .ready)
            return
        }
        try? await library.update(id) { $0.readiness = .processing }
        onProgress?(id, 0, .processing)
        do {
            if separator == nil { separator = try DemucsSeparator(modelURL: modelURL) }
            guard let separator else { return }
            let handler = onProgress
            let audio = try StereoAudio.load(URL(fileURLWithPath: song.filePath))
            let vocals = try separator.separateVocals(audio) { p in
                handler?(id, p * 0.95, .processing)
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
            try await library.update(id) { $0.readiness = .ready }
            onProgress?(id, 1, .ready)
        } catch {
            try? await library.update(id) { $0.readiness = .failed }
            onProgress?(id, 0, .failed)
        }
    }
}
