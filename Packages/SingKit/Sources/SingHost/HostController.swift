#if os(macOS)
import AppKit
import AVFoundation
import CryptoKit
import Foundation
import GRDB
import Observation
import SingCore

/// The Mac's brain: library, queue, playback, lyrics, pads and history, all on the main actor.
@MainActor
@Observable
public final class HostController: HostAPI {
    public let paths: SingPaths
    public let database: SingDatabase
    public let library: LibraryStore
    public let lyricsService: LyricsService
    public let stats: StatsService
    let separation: SeparationQueue
    @ObservationIgnored let playback = PlaybackEngine()
    @ObservationIgnored let mic = MicEngine()
    @ObservationIgnored var server: SingServer?
    @ObservationIgnored let bonjour = BonjourAdvertiser()
    @ObservationIgnored var broadcastTask: Task<Void, Never>?
    @ObservationIgnored var tickTask: Task<Void, Never>?
    @ObservationIgnored var currentPlay: PlayRecord?
    @ObservationIgnored let requestedPort: Int
    @ObservationIgnored let advertise: Bool

    public private(set) var songs: [SongSummary] = []
    public private(set) var artworkFiles: [SongID: URL] = [:]
    public private(set) var queue = QueueModel()
    public private(set) var nowPlaying = NowPlaying()
    public private(set) var lyrics: Lyrics?
    public private(set) var pitchTrack: PitchTrack? {
        didSet { displayPitch = pitchTrack.map { $0.version >= PitchTrack.currentVersion ? $0.coarse() : $0.simplified() } }
    }
    /// The trend shown on the TV; scoring keeps the detailed melody.
    public private(set) var displayPitch: PitchTrack?
    @ObservationIgnored public private(set) var livePoints: [LivePitchPoint] = []
    @ObservationIgnored public private(set) var liveScore: Int?
    @ObservationIgnored var scoreHits = 0
    @ObservationIgnored var scoreFrames = 0
    @ObservationIgnored var pitchTask: Task<Void, Never>?
    @ObservationIgnored var scoreKeeper = ScoreKeeper()
    public private(set) var lastResult: PerformanceResult?
    public private(set) var singers: [Singer] = []
    public private(set) var session: SessionInfo?
    public private(set) var preparing: [SongID: Double] = [:]
    public internal(set) var connectedPads: [PadIdentity] = []
    public private(set) var importProgress: (done: Int, total: Int)?
    public internal(set) var lastError: String?
    public private(set) var countdownEnd: Date?
    public private(set) var serverRunning = false
    @ObservationIgnored var ownerPINHash: String?
    @ObservationIgnored var ownerTokens: [String: Date] = [:]
    @ObservationIgnored var pinAttempts: [String: AttemptGuard] = [:]
    @ObservationIgnored var pairGuard = AttemptGuard()
    @ObservationIgnored var evicted = Set<SongID>()
    @ObservationIgnored var lowDiskWarned = false
    @ObservationIgnored var processingStartedAt: Date?
    @ObservationIgnored var lastStorageCheck = Date.distantPast
    public internal(set) var processingHeld = false
    public internal(set) var restUntil: Date?
    public var hostCode: String
    public var guestCode: String
    public var settings: SingSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.network.bonjourName != oldValue.network.bonjourName { readvertise() }
            applySettings()
            persistSettings()
            scheduleBroadcast()
        }
    }
    public var outputDeviceUID: String? {
        didSet { UserDefaults.standard.set(outputDeviceUID, forKey: "outputDeviceUID"); playback.setOutputDevice(uid: outputDeviceUID); mic.configure(inputUID: inputDeviceUID, outputUID: outputDeviceUID) }
    }
    public var inputDeviceUID: String? {
        didSet { UserDefaults.standard.set(inputDeviceUID, forKey: "inputDeviceUID"); mic.configure(inputUID: inputDeviceUID, outputUID: outputDeviceUID) }
    }
    public var lyricOffset: Double = UserDefaults.standard.double(forKey: "lyricOffset") {
        didSet { UserDefaults.standard.set(lyricOffset, forKey: "lyricOffset") }
    }

    public var micLevel: Float { mic.level }
    public var micRunning: Bool { mic.isRunning }
    public var serverName: String { Host.current().localizedName ?? "Sing! Mac" }
    public var port: Int { server?.port ?? requestedPort }

    public init(paths: SingPaths = .default, modelURL: URL? = nil, port: Int = SingProtocol.defaultPort, advertise: Bool = true) throws {
        self.paths = paths
        self.advertise = advertise
        try paths.ensure()
        Self.installBundledModels(into: paths.models)
        database = try SingDatabase.open(at: paths.database)
        library = LibraryStore(db: database, paths: paths)
        stats = StatsService(db: database)
        let model = modelURL ?? Self.locateModel(paths: paths)
        separation = SeparationQueue(library: library, paths: paths, modelURL: model)
        let stored = try? database.writer.read { try SettingRecord.fetchOne($0, key: "settings") }
        let initial = stored.flatMap { try? SingProtocol.decoder().decode(SingSettings.self, from: Data($0.json.utf8)) } ?? SingSettings()
        settings = initial
        self.requestedPort = port == SingProtocol.defaultPort ? initial.network.port : port
        let code = UserDefaults.standard.string(forKey: "hostCode") ?? Self.newCode()
        hostCode = code
        guestCode = Self.newCode()
        outputDeviceUID = UserDefaults.standard.string(forKey: "outputDeviceUID")
        inputDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
        let settingsBox = SettingsBox(initial.services)
        servicesBox = settingsBox
        lyricsService = LyricsService(library: library, paths: paths, services: { settingsBox.value })
        UserDefaults.standard.set(code, forKey: "hostCode")
        playback.onFinished = { [weak self] in self?.songFinished(skipped: false) }
        applySettings()
        playback.setOutputDevice(uid: outputDeviceUID)
        mic.configure(inputUID: inputDeviceUID, outputUID: outputDeviceUID)
    }

    @ObservationIgnored let servicesBox: SettingsBox

    final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: ServiceSettings
        init(_ v: ServiceSettings) { _value = v }
        var value: ServiceSettings {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    /// A DMG build carries the Core ML models; the first launch copies them where the host looks for them.
    static func installBundledModels(into dir: URL) {
        for name in ["htdemucs", "crepe_full", "ecapa"] {
            let dest = dir.appendingPathComponent("\(name).mlmodelc")
            guard !FileManager.default.fileExists(atPath: dest.path),
                  let src = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else { continue }
            try? FileManager.default.copyItem(at: src, to: dest)
        }
    }

    static func newCode() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }

    static func locateModel(paths: SingPaths) -> URL {
        let candidates = [
            paths.models.appendingPathComponent("htdemucs.mlmodelc"),
            paths.models.appendingPathComponent("htdemucs.mlpackage"),
            Bundle.main.url(forResource: "htdemucs", withExtension: "mlmodelc"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    public var modelAvailable: Bool { FileManager.default.fileExists(atPath: Self.locateModel(paths: paths).path) }

    public func clearError() { lastError = nil }

    // MARK: Lifecycle

    public func start() async {
        await separation.setProgressHandler { [weak self] id, p, r in
            Task { @MainActor in self?.separationProgress(id, p, r) }
        }
        await separation.setPostProcess { [weak self] id in await self?.postProcess(id) }
        await reloadLibrary()
        await reloadSingers()
        await loadRequests()
        await loadOwnerPIN()
        await loadEvicted()
        await restoreQueue()
        startServer()
        startWatching()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
        let pending = songs.filter { $0.readiness != .ready && $0.readiness != .missingFile && !evicted.contains($0.id) }.map(\.id)
        let env = ProcessInfo.processInfo.environment
        if modelAvailable, env["SING_NO_SEP"] == nil { await separation.enqueueBackground(pending) }
        Task { await upgradeLyricsInBackground() }
        if settings.playback.micEnabled, env["SING_NO_MIC"] == nil { await startMic() }
    }

    func startServer() {
        let server = SingServer(api: self, port: requestedPort)
        self.server = server
        Task {
            do {
                try await server.start()
                serverRunning = true
                if advertise { bonjour.start(name: advertisedName, port: server.port) }
            } catch {
                serverRunning = false
                lastError = "Pads cannot connect: port \(server.port) is busy (\(error.localizedDescription))."
            }
        }
    }

    /// Opens the web remote on any phone; the iPad and Android apps read the same link to pair.
    public var joinURL: String {
        "http://\(Self.localIPv4() ?? "localhost"):\(port)/join?code=\(guestCode)"
    }

    public var hostJoinURL: String {
        "sing://\(Self.localIPv4() ?? "localhost"):\(port)?code=\(hostCode)&name=\(serverName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
    }

    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "en0" { return ip }
            best = best ?? ip
        }
        return best
    }

    // MARK: Library

    public func reloadLibrary() async {
        let counts = (try? await library.playCounts()) ?? [:]
        let all = (try? await library.all()) ?? []
        songs = all.map { $0.summary(playCount: counts[$0.id ?? 0] ?? 0, progress: preparing[$0.id ?? 0]) }
        artworkFiles = Dictionary(uniqueKeysWithValues: all.compactMap { r in r.hasArtwork ? (r.id ?? 0, paths.artwork(r.audioHash)) : nil })
    }

    public func importFiles(_ urls: [URL]) async {
        importProgress = (0, 0)
        let result = await library.importFiles(urls) { done, total in
            Task { @MainActor in self.importProgress = (done, total) }
        }
        importProgress = nil
        await reloadLibrary()
        if !result.failed.isEmpty { lastError = "Could not import: \(result.failed.joined(separator: ", "))" }
        if modelAvailable {
            await separation.enqueueBackground(songs.filter { $0.readiness != .ready }.map(\.id))
        }
        await fulfillRequests()
        scheduleBroadcast()
    }

    // MARK: Watch folder

    /// Audio files dropped in this folder are imported automatically (MAC-LIB-03).
    public var watchFolder: URL? {
        get { UserDefaults.standard.url(forKey: "watchFolder") }
        set { UserDefaults.standard.set(newValue, forKey: "watchFolder"); startWatching() }
    }
    @ObservationIgnored var watchTask: Task<Void, Never>?
    @ObservationIgnored var knownWatchFiles = Set<String>()

    func startWatching() {
        watchTask?.cancel()
        guard let folder = watchFolder else { return }
        knownWatchFiles = []
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                let files = LibraryStore.audioFiles(in: [folder]).filter { !self.knownWatchFiles.contains($0.path) }
                let settled = files.filter { url in
                    let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return Date.now.timeIntervalSince(m) > 3
                }
                guard !settled.isEmpty else { continue }
                for f in settled { self.knownWatchFiles.insert(f.path) }
                await self.importFiles(settled)
            }
        }
    }

    /// A requested song that arrives in the library is queued for the people who asked for it.
    func fulfillRequests() async {
        for r in requests {
            let key = normalizeForMatch(r.track.title) + "|" + normalizeForMatch(Self.firstArtist(r.track.artist))
            guard let song = songs.first(where: { normalizeForMatch($0.title) + "|" + normalizeForMatch(Self.firstArtist($0.artist)) == key || ($0.isrc != nil && $0.isrc == r.track.isrc) }) else { continue }
            dismissRequest(r.id)
            try? await enqueue(songID: song.id, singerIDs: r.singers.map(\.id), playNext: false, by: nil)
            Task { await server?.broadcast(.toast(.init(message: "\(song.title) is now in the library and queued"))) }
        }
    }

    func separationProgress(_ id: SongID, _ p: Double, _ r: Readiness) {
        if r == .ready || r == .failed {
            preparing[id] = nil
        } else {
            preparing[id] = p
            if processingStartedAt == nil { processingStartedAt = .now }
        }
        if let i = songs.firstIndex(where: { $0.id == id }) {
            songs[i].readiness = r
            songs[i].progress = preparing[id]
        }
        Task { await server?.broadcast(.progress(.init(songID: id, progress: p, readiness: r))) }
        if r == .ready || r == .failed { scheduleBroadcast() }
        if r == .ready, nowPlaying.state == .preparing, nowPlaying.entry?.song.id == id {
            Task { await startPrepared() }
        }

    }

    /// Everything after separation, in order: lyrics (with AI timing and singer detection), then pitch.
    func postProcess(_ id: SongID) async {
        separationProgress(id, 0.75, .processing)
        await refreshLyrics(id)
        separationProgress(id, 0.88, .processing)
        if let record = try? await library.song(id) {
            let track = await loadPitch(record)
            if nowPlaying.entry?.song.id == id { pitchTrack = track }
        }
        separationProgress(id, 0.98, .processing)
    }

    /// Resolves lyrics again (providers, then on-device alignment) and swaps them in if the song is on.
    public func refreshLyrics(_ id: SongID, force: Bool = false) async {
        guard let record = try? await library.song(id) else { return }
        if force { try? FileManager.default.removeItem(at: paths.lyrics(record.audioHash)); try? FileManager.default.removeItem(at: paths.songCache(record.audioHash).appendingPathComponent("align-failed")) }
        let before = lyricsService.cached(record)?.kind
        guard let l = await lyricsService.resolve(record, refresh: force) else { return }
        if force { try? FileManager.default.removeItem(at: paths.songCache(record.audioHash).appendingPathComponent("diarized")) }
        if force || before != l.kind { try? FileManager.default.removeItem(at: paths.pitch(record.audioHash)) }
        if nowPlaying.entry?.song.id == id { lyrics = l.shifted(by: Double(record.lyricOffsetMs) / 1000) }
        if let i = songs.firstIndex(where: { $0.id == id }) {
            songs[i].lyricsKind = l.kind
            songs[i].isDuet = l.isDuet
        }
        scheduleBroadcast()
    }

    /// Reference melody from the cache, or extracted now from the vocal stem.
    func loadPitch(_ record: SongRecord) async -> PitchTrack? {
        let url = paths.pitch(record.audioHash)
        let crepe = paths.models.appendingPathComponent("crepe_full.mlmodelc")
        let hasCrepe = FileManager.default.fileExists(atPath: crepe.path)
        if let d = try? Data(contentsOf: url), let t = try? JSONDecoder().decode(PitchTrack.self, from: d),
           t.version >= PitchTrack.currentVersion || !hasCrepe {
            return t
        }
        let vocals = paths.vocals(record.audioHash)
        guard FileManager.default.fileExists(atPath: vocals.path) else { return nil }
        let lyrics = lyricsService.cached(record)
        let track = await Task.detached(priority: .userInitiated) { () -> PitchTrack? in
            if hasCrepe, let ex = try? CrepeExtractor(modelURL: crepe), let t = try? ex.extract(vocals: vocals, lyrics: lyrics) { return t }
            return try? MelodyExtractor.extract(vocals: vocals)
        }.value
        if let track, let d = try? JSONEncoder().encode(track) { try? d.write(to: url) }
        return track
    }

    func resetLiveScore() {
        livePoints = []
        liveScore = nil
        scoreHits = 0
        scoreFrames = 0
        scoreKeeper = ScoreKeeper()
        pitchTask?.cancel()
        pitchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                self?.samplePitch()
            }
        }
    }

    func samplePitch() {
        guard nowPlaying.state == .playing else { return }
        let t = lyricTime
        livePoints.removeAll { $0.time < t - 6 || $0.time > t + 0.5 }
        scoreKeeper.add(time: t, sungMidi: mic.livePitch.midi, level: mic.level)
        guard let sung = mic.livePitch.midi else { return }
        let target = pitchTrack?.target(at: t)
        let folded = target.map { PitchTrack.foldOctave(sung, toward: $0) } ?? sung
        let hit = target.map { abs(folded - $0) < 1.0 } ?? false
        livePoints.append(LivePitchPoint(time: t, midi: folded, onTarget: hit))
        if target != nil {
            scoreFrames += 1
            if hit { scoreHits += 1 }
            liveScore = Int((Double(scoreHits) / Double(max(scoreFrames, 1)) * 100).rounded())
        }
    }

    func upgradeLyricsInBackground() async {
        for s in songs where s.readiness == .ready {
            await refreshLyrics(s.id)
            if let r = try? await library.song(s.id) { _ = await loadPitch(r) }
        }
    }

    // MARK: Singers

    public func reloadSingers() async {
        singers = (try? await database.writer.read { try SingerRecord.order(Column("name")).fetchAll($0) })?.map(\.singer) ?? []
    }

    @discardableResult
    public func addSinger(name: String, emoji: String?, padID: String?) async throws -> Singer {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ErrorBody(code: "name", message: "A name is needed") }
        if let existing = singers.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { return existing }
        let color = Singer.palette[singers.count % Singer.palette.count]
        let record = try await database.writer.write { db -> SingerRecord in
            var r = SingerRecord(name: trimmed, emoji: emoji, colorHex: color, createdByPad: padID)
            try r.insert(db)
            return r
        }
        await reloadSingers()
        scheduleBroadcast()
        return record.singer
    }

    // MARK: Queue

    public func enqueue(songID: SongID, singerIDs: [SingerID], playNext: Bool, by pad: String?) async throws {
        guard let record = try await library.song(songID) else { throw QueueError.notFound }
        let chosen = singers.filter { singerIDs.contains($0.id) }
        let entry = QueueEntry(song: summary(record), singers: chosen, addedBy: pad)
        try queue.add(entry, playNext: playNext, maxPerSinger: settings.queue.maxQueuedPerSinger)
        await logQueueEvent("added", songID: songID, singers: singerIDs, pad: pad)
        if evicted.remove(songID) != nil { saveEvicted() }
        await separation.prioritize(songID)
        persistQueue()
        scheduleBroadcast()
        notifyUpcoming()
        if nowPlaying.state == .idle || nowPlaying.state == .finished { await self.playNext() }
    }

    public func removeFromQueue(_ id: String, by pad: PadIdentity?) throws {
        if let pad, pad.role != .host {
            guard settings.queue.guestsCanRemoveOwn, queue.entries.first(where: { $0.id == id })?.addedBy == pad.padID else { throw QueueError.notAllowed }
        }
        let removed = try queue.remove(id)
        Task { await logQueueEvent("removed", songID: removed.song.id, singers: removed.singers.map(\.id), pad: pad?.padID) }
        persistQueue()
        scheduleBroadcast()
    }

    public func moveInQueue(_ id: String, to index: Int) throws {
        try queue.move(id, to: index)
        persistQueue()
        scheduleBroadcast()
        notifyUpcoming()
    }

    func summary(_ r: SongRecord) -> SongSummary {
        songs.first { $0.id == r.id } ?? r.summary()
    }

    func persistQueue() {
        let entries = queue.entries
        Task {
            try? await database.writer.write { db in
                try QueueEntryRecord.deleteAll(db)
                for (i, e) in entries.enumerated() {
                    let ids = String(decoding: try JSONEncoder().encode(e.singers.map(\.id)), as: UTF8.self)
                    try QueueEntryRecord(id: e.id, position: i, songId: e.song.id, singerIds: ids, addedBy: e.addedBy, addedAt: e.addedAt).insert(db)
                }
            }
        }
    }

    func restoreQueue() async {
        let rows = (try? await database.writer.read { try QueueEntryRecord.order(Column("position")).fetchAll($0) }) ?? []
        var model = QueueModel()
        for r in rows {
            guard let song = songs.first(where: { $0.id == r.songId }) else { continue }
            let ids = (try? JSONDecoder().decode([Int64].self, from: Data(r.singerIds.utf8))) ?? []
            try? model.add(QueueEntry(id: r.id, song: song, singers: singers.filter { ids.contains($0.id) }, addedBy: r.addedBy, addedAt: r.addedAt))
        }
        queue = model
    }

    func logQueueEvent(_ type: String, songID: SongID, singers: [SingerID], pad: String?) async {
        let ids = String(decoding: (try? JSONEncoder().encode(singers)) ?? Data(), as: UTF8.self)
        let sessionID = session?.id
        try? await database.writer.write { db in
            var e = QueueEventRecord(sessionId: sessionID, type: type, songId: songID, singerIds: ids, padId: pad)
            try e.insert(db)
        }
    }

    func notifyUpcoming() {
        for (i, e) in queue.entries.prefix(3).enumerated() {
            for s in e.singers {
                Task { await server?.broadcast(.youreUp(.init(songsAway: i + 1, entryID: e.id, singerID: s.id))) }
            }
        }
    }

    // MARK: Sessions

    public func startSession(name: String? = nil) async {
        guard session == nil else { return }
        let r = try? await database.writer.write { db -> SessionRecord in
            var s = SessionRecord(name: name)
            try s.insert(db)
            return s
        }
        if let r, let id = r.id { session = SessionInfo(id: id, name: r.name, startedAt: r.startedAt, playCount: 0) }
        scheduleBroadcast()
    }

    public func endSession() async {
        guard let s = session else { return }
        try? await database.writer.write { db in
            try db.execute(sql: "UPDATE session SET endedAt = ? WHERE id = ?", arguments: [Date.now, s.id])
        }
        session = nil
        scheduleBroadcast()
    }

    // MARK: Playback

    public func playNext() async {
        finishCurrentPlay(skipped: nowPlaying.state == .playing || nowPlaying.state == .paused)
        playback.stop()
        lyrics = nil
        pitchTrack = nil
        guard let entry = queue.popNext() else {
            nowPlaying = NowPlaying(state: .idle, guideVocal: settings.playback.defaultGuideVocal)
            persistQueue()
            scheduleBroadcast()
            return
        }
        persistQueue()
        notifyUpcoming()
        if session == nil { await startSession() }
        nowPlaying = NowPlaying(entry: entry, state: .preparing, positionMs: 0, positionAt: .now, guideVocal: settings.playback.defaultGuideVocal)
        scheduleBroadcast()
        guard let record = try? await library.song(entry.song.id) else { return }
        async let lyr = lyricsService.resolve(record)
        let stems = await separation.isReady(record)
        let ready = record.readiness == .ready && stems
        lyrics = await lyr.map { $0.shifted(by: Double(record.lyricOffsetMs) / 1000) }
        if ready || settings.playback.playOriginalWhenNotReady || !modelAvailable {
            await startPrepared()
        } else {
            await separation.prioritize(entry.song.id)
        }
    }

    func startPrepared() async {
        guard let entry = nowPlaying.entry, let record = try? await library.song(entry.song.id) else { return }
        let ready = await separation.isReady(record)
        do {
            if ready {
                try playback.load(instrumental: paths.instrumental(record.audioHash), vocals: paths.vocals(record.audioHash))
            } else {
                try playback.load(instrumental: URL(fileURLWithPath: record.filePath), vocals: nil)
            }
        } catch {
            lastError = "Could not play \(record.title): \(error.localizedDescription)"
            await playNext()
            return
        }
        if lyrics == nil { lyrics = await lyricsService.resolve(record) }
        pitchTrack = await loadPitch(record)
        resetLiveScore()
        tvTranslation = nil
        Task { await refreshTVTranslation() }
        playback.guideVocal = record.defaultGuideVocal ?? settings.playback.defaultGuideVocal
        nowPlaying.guideVocal = playback.guideVocal
        if settings.playback.countdownBetweenSongs {
            nowPlaying.state = .countdown
            countdownEnd = .now.addingTimeInterval(3)
            scheduleBroadcast()
            try? await Task.sleep(for: .seconds(3))
            countdownEnd = nil
            guard nowPlaying.entry?.id == entry.id, nowPlaying.state == .countdown else { return }
        }
        do {
            try playback.play(from: 0)
            nowPlaying.state = .playing
            nowPlaying.positionMs = 0
            nowPlaying.positionAt = .now
            beginPlay(entry)
        } catch {
            lastError = "Audio output error: \(error.localizedDescription)"
        }
        scheduleBroadcast()
    }

    public func togglePause() {
        switch nowPlaying.state {
        case .playing:
            playback.pause()
            nowPlaying.state = .paused
        case .paused:
            try? playback.play()
            nowPlaying.state = .playing
        case .idle, .finished:
            Task { await playNext() }
            return
        default: return
        }
        syncPosition()
        scheduleBroadcast()
    }

    public func restart() {
        guard nowPlaying.entry != nil else { return }
        try? playback.play(from: 0)
        nowPlaying.state = .playing
        syncPosition()
        scheduleBroadcast()
    }

    public func seek(to seconds: Double) {
        try? playback.seek(to: seconds)
        syncPosition()
        scheduleBroadcast()
    }

    public func stopPlayback() {
        finishCurrentPlay(skipped: true)
        playback.stop()
        nowPlaying = NowPlaying(state: .idle, guideVocal: settings.playback.defaultGuideVocal)
        lyrics = nil
        scheduleBroadcast()
    }

    public func setGuideVocal(_ v: Double) {
        let clamped = max(0, min(1, v))
        playback.guideVocal = clamped
        nowPlaying.guideVocal = clamped
        scheduleBroadcast()
    }

    func songFinished(skipped: Bool) {
        let entry = nowPlaying.entry
        let scored = scoreKeeper.result(track: pitchTrack, upTo: playback.duration)
        nowPlaying.state = .finished
        pitchTask?.cancel()
        if let entry {
            let cats = scored?.categories ?? []
            let total = scored?.total
            var badges: [String] = []
            if let best = cats.max(by: { $0.value < $1.value }), best.value >= 85 { badges.append("\(best.name) \(best.value)") }
            if (cats.first { $0.name == "Coverage" }?.value ?? 0) >= 95 { badges.append("Every note sung") }
            lastResult = PerformanceResult(
                entryID: entry.id, songTitle: entry.song.title, artist: entry.song.artist, singers: entry.singers,
                total: total, grade: total.map(ScoreKeeper.grade), title: total == nil ? "Bravo!" : ScoreKeeper.title(for: cats),
                comment: total == nil ? "No singing was picked up by the mic, but what a performance." : Self.comment(total!, cats),
                categories: cats, badges: badges, leaderboard: []
            )
        }
        finishCurrentPlay(skipped: skipped, score: scored.map { Double($0.total) })
        scheduleBroadcast()
        let hold = max(7, settings.tv.resultSeconds)
        let id = entry?.id
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if let board = try? await self.leaderboard(), self.lastResult?.entryID == id {
                self.lastResult?.leaderboard = board
                self.scheduleBroadcast()
            }
        }
        if settings.playback.autoAdvance {
            Task {
                try? await Task.sleep(for: .seconds(hold))
                if self.nowPlaying.state == .finished, self.nowPlaying.entry?.id == id { await self.playNext() }
            }
        }
    }

    static func comment(_ total: Int, _ cats: [ScoreCategory]) -> String {
        let worst = cats.min { $0.value < $1.value }
        switch total {
        case 90...: return "Huge. The room is still clapping."
        case 75..<90: return worst.map { "Great run. Only \($0.name.lowercased()) kept it from the top." } ?? "Great run."
        case 55..<75: return worst.map { "Nice one. Next time, watch the \($0.name.lowercased())." } ?? "Nice one."
        default: return "Brave choice. Try it again with a little guide vocal."
        }
    }

    func leaderboard() async throws -> [RankedName] {
        let sid = session?.id
        return try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT si.name name, si.colorHex color, MAX(p.score) best FROM play p
                JOIN playSinger ps ON ps.playId = p.id JOIN singer si ON si.id = ps.singerId
                WHERE p.score IS NOT NULL AND (? IS NULL OR p.sessionId = ?)
                GROUP BY si.id ORDER BY best DESC LIMIT 5
                """, arguments: [sid, sid]).map { RankedName(name: $0["name"], count: Int(($0["best"] as Double?) ?? 0), colorHex: $0["color"]) }
        }
    }

    /// Time to show lyrics at: what is heard right now, after output latency and the user's offset.
    public var lyricTime: TimeInterval {
        playback.position - playback.outputLatency + lyricOffset
    }

    public var duration: TimeInterval { playback.duration }

    func syncPosition() {
        nowPlaying.positionMs = Int(playback.position * 1000)
        nowPlaying.positionAt = .now
    }

    @ObservationIgnored var lastMicState: MicStatus.State?

    func tick() async {
        let ms = micStatus.state
        if ms != lastMicState { lastMicState = ms; micStateText = micStatus.message; scheduleBroadcast() }
        guard nowPlaying.state == .playing else { return }
        syncPosition()
        let idx = lyrics?.lineIndex(at: lyricTime)
        let line = idx.flatMap { lyrics?.lines[$0].text }
        let next = idx.map { $0 + 1 }.flatMap { i in (lyrics?.lines.indices.contains(i) ?? false) ? lyrics?.lines[i].text : nil }
            ?? (idx == nil ? lyrics?.lines.first?.text : nil)
        if line != nowPlaying.currentLine || next != nowPlaying.nextLine {
            nowPlaying.currentLine = line
            nowPlaying.nextLine = next
        }
        await server?.broadcast(.position(.init(positionMs: nowPlaying.positionMs, at: nowPlaying.positionAt, lineIndex: idx)))
        connectedPads = await server?.connectedPads() ?? []
        if preparing.isEmpty { processingStartedAt = nil }
        updateProcessingHold()
        if Date.now.timeIntervalSince(lastStorageCheck) > 300 {
            lastStorageCheck = .now
            Task { await enforceStorageLimits() }
        }
    }

    // MARK: History

    func beginPlay(_ entry: QueueEntry) {
        let sessionID = session?.id
        let guide = playback.guideVocal
        let singerIDs = entry.singers.map(\.id)
        Task {
            let rec = try? await database.writer.write { db -> PlayRecord in
                var p = PlayRecord(songId: entry.song.id, sessionId: sessionID, guideVocal: guide)
                try p.insert(db)
                for s in singerIDs { try PlaySingerRecord(playId: p.id!, singerId: s).insert(db) }
                try db.execute(sql: "UPDATE song SET lastPlayedAt = ? WHERE id = ?", arguments: [Date.now, entry.song.id])
                return p
            }
            self.currentPlay = rec
            if var s = self.session { s.playCount += 1; self.session = s }
        }
    }

    func finishCurrentPlay(skipped: Bool, score: Double? = nil) {
        guard var play = currentPlay else { return }
        play.score = score
        currentPlay = nil
        let duration = max(playback.duration, 1)
        play.endedAt = .now
        play.percentCompleted = min(1, playback.position / duration)
        play.skipped = skipped && play.percentCompleted < 0.5
        let final = play
        Task {
            try? await database.writer.write { db in try final.update(db) }
            await reloadLibrary()
        }
    }

    // MARK: Settings

    public private(set) var micPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    public func startMic() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micPermission == .authorized else {
            lastError = "Sing! cannot use the microphone. Allow it in System Settings, Privacy & Security, Microphone."
            return
        }
        do {
            try mic.start()
            micStartedAt = .now
            micError = nil
        } catch {
            micError = error.localizedDescription
            lastError = "Microphone: \(error.localizedDescription)"
        }
        scheduleBroadcast()
    }

    @ObservationIgnored var micStartedAt: Date?
    public private(set) var micStateText: String?
    @ObservationIgnored var micError: String?

    public var micStatus: MicStatus {
        let perm = AVCaptureDevice.authorizationStatus(for: .audio)
        if !settings.playback.micEnabled { return MicStatus(state: .off) }
        if perm == .notDetermined { return MicStatus(state: .needsPermission, message: "Sing! is waiting for microphone permission.") }
        if perm == .denied || perm == .restricted {
            return MicStatus(state: .denied, message: "Microphone access is off for Sing!. Turn it on in System Settings, Privacy & Security, Microphone.")
        }
        if let micError { return MicStatus(state: .failed, deviceName: mic.deviceName, message: micError) }
        guard mic.isRunning else { return MicStatus(state: .failed, deviceName: mic.deviceName, message: "The microphone is not running.") }
        if let t = micStartedAt, Date.now.timeIntervalSince(t) > 2, mic.peakSinceStart == 0 {
            return MicStatus(state: .silent, deviceName: mic.deviceName, message: "macOS is sending silence: the permission for this build of Sing! is stale. Click Reset microphone permission, then allow it again.")
        }
        return MicStatus(state: .running, deviceName: mic.deviceName, level: mic.level)
    }

    /// Clears the stale microphone permission (each local build has a new signature) and asks again.
    public func resetMicPermission() {
        mic.stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Microphone", Bundle.main.bundleIdentifier ?? "io.github.yohann69.sing.mac"]
        try? p.run()
        p.waitUntilExit()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await startMic()
        }
    }

    func applySettings() {
        servicesBox.value = settings.services
        Task { await refreshTVTranslation() }
        playback.volume = settings.playback.musicVolume
        mic.gain = settings.playback.micGain
        mic.reverbMix = settings.playback.micReverb
        if settings.playback.micEnabled, !mic.isRunning, server != nil { Task { await startMic() } }
        if !settings.playback.micEnabled, mic.isRunning { mic.stop() }
    }

    func persistSettings() {
        guard let data = try? SingProtocol.encoder().encode(settings) else { return }
        let json = String(decoding: data, as: UTF8.self)
        Task { try? await database.writer.write { db in try SettingRecord(key: "settings", json: json).save(db) } }
    }

    // MARK: Broadcast

    public var liveStateSnapshot: LiveState {
        var np = nowPlaying
        if np.state == .playing { np.positionMs = Int(playback.position * 1000); np.positionAt = .now }
        return LiveState(
            nowPlaying: np,
            queue: queue.withEstimates(remainingCurrent: max(0, playback.duration - playback.position)),
            settings: settings, singers: singers, session: session, preparing: preparing, requests: requests, mic: micStatus,
            result: nowPlaying.state == .finished ? lastResult : nil
        )
    }

    func scheduleBroadcast() {
        broadcastTask?.cancel()
        broadcastTask = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await server?.broadcast(.state(liveStateSnapshot))
        }
    }

    // MARK: Pads

    public func regenerateGuestCode() { guestCode = Self.newCode() }

    public func revokeAllPads() async {
        try? await database.writer.write { db in try db.execute(sql: "UPDATE pad SET revoked = 1") }
    }

    static func hashToken(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: HostAPI

    public func serverInfo() async -> ServerInfo {
        ServerInfo(name: serverName, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1", livePort: port + 1)
    }

    public func pair(_ request: PairRequest) async throws -> PairResponse {
        guard request.protocolVersion >= SingProtocol.minimumSupportedVersion else {
            throw ErrorBody(code: "version", message: "Update the Sing! app on this device to connect to this Mac.")
        }
        try checkPairAttempt()
        let role: PadRole
        if request.code == hostCode { role = .host } else if request.code == guestCode { role = .guest } else {
            pairFailed()
            throw ErrorBody(code: "code", message: "That code is not right. Check the code on the TV or the Mac.")
        }
        pairSucceeded()
        let maxPads = settings.network.maxPads
        if maxPads > 0, await activePadCount >= maxPads {
            throw ErrorBody(code: "full", message: "This Mac already has \(maxPads) devices paired. Ask the host to unpair one.")
        }
        let token = UUID().uuidString + UUID().uuidString
        let pad = PadRecord(id: UUID().uuidString, name: request.deviceName, model: request.deviceModel, tokenHash: Self.hashToken(token), role: role, pairedAt: .now)
        try await database.writer.write { db in try pad.insert(db) }
        return PairResponse(token: token, padID: pad.id, role: role, server: await serverInfo())
    }

    public func authenticate(token: String) async -> PadIdentity? {
        let hash = Self.hashToken(token)
        guard let pad = try? await database.writer.read({ try PadRecord.filter(Column("tokenHash") == hash && Column("revoked") == false).fetchOne($0) }) else { return nil }
        return PadIdentity(padID: pad.id, name: pad.name, role: pad.role)
    }

    public func search(_ q: String, filters: SearchFilters) async throws -> SearchResponse {
        let found = try await library.search(q, filters: filters)
        let mapped = found.map { summary($0) }
        guard settings.services.catalogSearchEnabled, !filters.readyOnly, filters.favoritesOf == nil, !q.isEmpty else {
            return SearchResponse(songs: mapped, total: mapped.count)
        }
        let owned = Set(songs.map { normalizeForMatch($0.title) + "|" + normalizeForMatch(Self.firstArtist($0.artist)) })
        let isrcs = Set(songs.compactMap(\.isrc))
        let catalog = await CatalogSearch.search(q).filter { t in
            !(t.isrc.map(isrcs.contains) ?? false) && !owned.contains(normalizeForMatch(t.title) + "|" + normalizeForMatch(Self.firstArtist(t.artist)))
        }
        return SearchResponse(songs: mapped, total: mapped.count, catalog: catalog)
    }

    static func firstArtist(_ a: String) -> String {
        a.components(separatedBy: CharacterSet(charactersIn: ",&;")).first?.trimmingCharacters(in: .whitespaces) ?? a
    }

    public private(set) var requests: [SongRequest] = []

    func loadRequests() async {
        let stored = try? await database.writer.read { try SettingRecord.fetchOne($0, key: "requests") }
        requests = stored.flatMap { try? SingProtocol.decoder().decode([SongRequest].self, from: Data($0.json.utf8)) } ?? []
    }

    func saveRequests() {
        guard let data = try? SingProtocol.encoder().encode(requests) else { return }
        let json = String(decoding: data, as: UTF8.self)
        Task { try? await database.writer.write { db in try SettingRecord(key: "requests", json: json).save(db) } }
        scheduleBroadcast()
    }

    public func addRequest(_ track: CatalogTrack, singerIDs: [SingerID]) {
        if let i = requests.firstIndex(where: { $0.track.id == track.id }) {
            requests[i].votes += 1
            for s in singers where singerIDs.contains(s.id) && !requests[i].singers.contains(s) { requests[i].singers.append(s) }
        } else {
            requests.append(SongRequest(track: track, singers: singers.filter { singerIDs.contains($0.id) }))
        }
        saveRequests()
    }

    public func dismissRequest(_ id: String) {
        requests.removeAll { $0.id == id }
        saveRequests()
    }

    public func artwork(songID: SongID) async -> Data? {
        guard let s = try? await library.song(songID), s.hasArtwork else { return nil }
        return try? Data(contentsOf: paths.artwork(s.audioHash))
    }

    public func lyrics(songID: SongID, translateTo: String?) async -> Lyrics? {
        guard let s = try? await library.song(songID) else { return nil }
        var base: Lyrics? = nowPlaying.entry?.song.id == songID ? lyrics : nil
        if base == nil { base = await lyricsService.resolve(s) }
        guard let base, let lang = translateTo else { return base }
        return await translated(base, song: s, to: lang) ?? base
    }

    public func translationLanguages() async -> [TranslationLanguage] { await LyricsTranslator.languages() }

    /// A language pair macOS must download first; the Mac window asks the system to fetch it.
    public private(set) var pendingTranslationDownload: (source: String, target: String)?
    public private(set) var tvTranslation: Lyrics?

    func translated(_ l: Lyrics, song: SongRecord, to lang: String) async -> Lyrics? {
        let url = paths.songCache(song.audioHash).appendingPathComponent("translation-\(lang).json")
        if let d = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode(Lyrics.self, from: d), cached.lines.count == l.lines.count {
            return Self.mergeTranslation(cached, into: l)
        }
        do {
            let out = try await LyricsTranslator.translate(l, to: lang)
            if let d = try? JSONEncoder().encode(out) { try? d.write(to: url) }
            return out
        } catch LyricsTranslator.Failure.needsDownload(let s, let t) {
            pendingTranslationDownload = (s, t)
            return nil
        } catch {
            return nil
        }
    }

    static func mergeTranslation(_ t: Lyrics, into l: Lyrics) -> Lyrics {
        var out = l
        for i in out.lines.indices where i < t.lines.count { out.lines[i].translation = t.lines[i].translation }
        return out
    }

    /// Called by the Mac window once macOS has downloaded the language pair.
    public func translationDownloadFinished() {
        pendingTranslationDownload = nil
        Task { await refreshTVTranslation() }
    }

    func refreshTVTranslation() async {
        guard settings.tv.showTranslation, let lang = settings.tv.translationLanguage, let l = lyrics,
              let id = nowPlaying.entry?.song.id, let s = try? await library.song(id) else { tvTranslation = nil; return }
        tvTranslation = await translated(l, song: s, to: lang)
    }

    public func singers() async -> [Singer] { singers }

    public func createSinger(name: String, emoji: String?, pad: PadIdentity) async throws -> Singer {
        try await addSinger(name: name, emoji: emoji?.isEmpty == true ? nil : emoji, padID: pad.padID)
    }

    public func stats(_ period: StatsPeriod) async throws -> StatsResponse {
        try await stats.stats(period, sessionID: session?.id)
    }

    public func singerStats(_ id: SingerID) async throws -> SingerStats? {
        try await stats.singerStats(id)
    }

    public func suggestions(singerID: SingerID?) async throws -> [Suggestion] {
        let list = try await stats.suggestions(for: singerID)
        return list.map { s in Suggestion(song: songs.first { $0.id == s.song.id } ?? s.song, reason: s.reason) }
    }

    public func liveState() async -> LiveState { liveStateSnapshot }

    public func handle(_ message: ClientMessage, from pad: PadIdentity) async throws {
        let host = pad.role == .host
        switch message {
        case .enqueue(let e):
            guard host || settings.queue.guestsCanQueue else { throw QueueError.notAllowed }
            try await enqueue(songID: e.songID, singerIDs: e.singerIDs, playNext: e.playNext && host, by: pad.padID)
        case .remove(let id):
            try removeFromQueue(id, by: pad)
        case .move(let m):
            guard host else { throw QueueError.notAllowed }
            try moveInQueue(m.entryID, to: m.toIndex)
        case .transport(let c):
            guard host else { throw QueueError.notAllowed }
            switch c {
            case .play, .pause: togglePause()
            case .skip: await playNext()
            case .restart: restart()
            case .stop: stopPlayback()
            }
        case .seek(let ms):
            guard host else { throw QueueError.notAllowed }
            seek(to: Double(ms) / 1000)
        case .setGuideVocal(let v):
            guard host else { throw QueueError.notAllowed }
            setGuideVocal(v)
        case .updateSettings(let s):
            guard host else { throw QueueError.notAllowed }
            var incoming = s
            incoming.services = settings.services
            incoming.storage = settings.storage
            incoming.system = settings.system
            incoming.network = settings.network
            settings = incoming
        case .request(let r):
            addRequest(r.track, singerIDs: r.singerIDs)
        case .dismissRequest(let id):
            guard host else { throw QueueError.notAllowed }
            dismissRequest(id)
        case .ping, .auth:
            break
        }
    }

    public func padConnected(_ pad: PadIdentity, connected: Bool) async {
        try? await database.writer.write { db in
            try db.execute(sql: "UPDATE pad SET lastSeenAt = ? WHERE id = ?", arguments: [Date.now, pad.padID])
        }
        connectedPads = await server?.connectedPads() ?? []
    }
}
#endif
