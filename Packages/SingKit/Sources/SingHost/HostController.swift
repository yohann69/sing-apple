#if os(macOS)
import AppKit
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
    public private(set) var queue = QueueModel()
    public private(set) var nowPlaying = NowPlaying()
    public private(set) var lyrics: Lyrics?
    public private(set) var singers: [Singer] = []
    public private(set) var session: SessionInfo?
    public private(set) var preparing: [SongID: Double] = [:]
    public private(set) var connectedPads: [PadIdentity] = []
    public private(set) var importProgress: (done: Int, total: Int)?
    public private(set) var lastError: String?
    public private(set) var countdownEnd: Date?
    public private(set) var serverRunning = false
    public var hostCode: String
    public var guestCode: String
    public var settings: SingSettings {
        didSet {
            guard settings != oldValue else { return }
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
        self.requestedPort = port
        self.advertise = advertise
        try paths.ensure()
        database = try SingDatabase.open(at: paths.database)
        library = LibraryStore(db: database, paths: paths)
        stats = StatsService(db: database)
        let model = modelURL ?? Self.locateModel(paths: paths)
        separation = SeparationQueue(library: library, paths: paths, modelURL: model)
        let stored = try? database.writer.read { try SettingRecord.fetchOne($0, key: "settings") }
        let initial = stored.flatMap { try? SingProtocol.decoder().decode(SingSettings.self, from: Data($0.json.utf8)) } ?? SingSettings()
        settings = initial
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

    // MARK: Lifecycle

    public func start() async {
        await separation.setProgressHandler { [weak self] id, p, r in
            Task { @MainActor in self?.separationProgress(id, p, r) }
        }
        await reloadLibrary()
        await reloadSingers()
        await restoreQueue()
        startServer()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
        let pending = songs.filter { $0.readiness != .ready && $0.readiness != .missingFile }.map(\.id)
        if modelAvailable { await separation.enqueueBackground(pending) }
        if settings.playback.micEnabled { try? mic.start() }
    }

    func startServer() {
        let server = SingServer(api: self, port: requestedPort)
        self.server = server
        Task.detached {
            do {
                await MainActor.run { self.serverRunning = true }
                try await server.run()
            } catch {
                await MainActor.run { self.serverRunning = false; self.lastError = "Pad server stopped: \(error)" }
            }
        }
        if advertise { bonjour.start(name: serverName, port: server.port) }
    }

    public var joinURL: String {
        "sing://\(Self.localIPv4() ?? "localhost"):\(port)?code=\(guestCode)&name=\(serverName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
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
        scheduleBroadcast()
    }

    func separationProgress(_ id: SongID, _ p: Double, _ r: Readiness) {
        if r == .ready || r == .failed {
            preparing[id] = nil
        } else {
            preparing[id] = p
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
        let ready = await separation.isReady(record)
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
        nowPlaying.state = .finished
        finishCurrentPlay(skipped: skipped)
        scheduleBroadcast()
        if settings.playback.autoAdvance {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.nowPlaying.state == .finished { await self.playNext() }
            }
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

    func tick() async {
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

    func finishCurrentPlay(skipped: Bool) {
        guard var play = currentPlay else { return }
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

    func applySettings() {
        servicesBox.value = settings.services
        playback.volume = settings.playback.musicVolume
        mic.gain = settings.playback.micGain
        mic.reverbMix = settings.playback.micReverb
        if settings.playback.micEnabled, !mic.isRunning, server != nil { try? mic.start() }
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
            settings: settings, singers: singers, session: session, preparing: preparing
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
        ServerInfo(name: serverName, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")
    }

    public func pair(_ request: PairRequest) async throws -> PairResponse {
        guard request.protocolVersion >= SingProtocol.minimumSupportedVersion else {
            throw ErrorBody(code: "version", message: "Update the Sing! app on this device to connect to this Mac.")
        }
        let role: PadRole
        if request.code == hostCode { role = .host } else if request.code == guestCode { role = .guest } else {
            throw ErrorBody(code: "code", message: "That code is not right. Check the code on the TV or the Mac.")
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
        return SearchResponse(songs: mapped, total: mapped.count)
    }

    public func artwork(songID: SongID) async -> Data? {
        guard let s = try? await library.song(songID), s.hasArtwork else { return nil }
        return try? Data(contentsOf: paths.artwork(s.audioHash))
    }

    public func lyrics(songID: SongID) async -> Lyrics? {
        if nowPlaying.entry?.song.id == songID, let lyrics { return lyrics }
        guard let s = try? await library.song(songID) else { return nil }
        return await lyricsService.resolve(s)
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
            settings = incoming
        case .ping:
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
