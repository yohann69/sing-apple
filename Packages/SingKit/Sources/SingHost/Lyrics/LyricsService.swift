import Foundation
import SingCore

public final class LyricsService: Sendable {
    let library: LibraryStore
    let paths: SingPaths
    let services: @Sendable () -> ServiceSettings

    public init(library: LibraryStore, paths: SingPaths, services: @escaping @Sendable () -> ServiceSettings) {
        self.library = library
        self.paths = paths
        self.services = services
    }

    public func cached(_ song: SongRecord) -> Lyrics? {
        guard let data = try? Data(contentsOf: paths.lyrics(song.audioHash)) else { return nil }
        return try? JSONDecoder().decode(Lyrics.self, from: data)
    }

    /// Lyrics fixed by hand in the sync editor; providers never replace them unless asked.
    public func saveManual(_ song: SongRecord, _ lyrics: Lyrics) throws {
        var l = lyrics
        l.source = .manual
        try FileManager.default.createDirectory(at: paths.songCache(song.audioHash), withIntermediateDirectories: true)
        try JSONEncoder().encode(l).write(to: paths.lyrics(song.audioHash))
    }

    actor InFlight {
        var tasks: [String: Task<Lyrics?, Never>] = [:]
        func run(_ key: String, _ body: @escaping @Sendable () async -> Lyrics?) async -> Lyrics? {
            if let t = tasks[key] { return await t.value }
            let t = Task { await body() }
            tasks[key] = t
            let v = await t.value
            tasks[key] = nil
            return v
        }
    }

    let inFlight = InFlight()

    var alignFailedMarker: (SongRecord) -> URL { { self.paths.songCache($0.audioHash).appendingPathComponent("align-failed") } }

    func canAlign(_ song: SongRecord) -> Bool {
        services().aiAlignmentEnabled
            && FileManager.default.fileExists(atPath: paths.vocals(song.audioHash).path)
            && !FileManager.default.fileExists(atPath: alignFailedMarker(song).path)
    }

    /// Cache first, then local files and every provider; the richest timing wins. When only
    /// line or plain lyrics exist and the vocal stem is ready, on-device speech alignment makes them word synced.
    public func resolve(_ song: SongRecord, refresh: Bool = false) async -> Lyrics? {
        let undiarized = !FileManager.default.fileExists(atPath: paths.songCache(song.audioHash).appendingPathComponent("diarized").path)
            && FileManager.default.fileExists(atPath: paths.vocals(song.audioHash).path)
        if !refresh, let c = cached(song), c.source == .manual { return c }
        if !refresh, let c = cached(song), !undiarized || c.isDuet, c.kind >= .word || (!canAlign(song) && c.source != .embedded) { return c }
        return await inFlight.run(song.audioHash) {
            var best = refresh ? nil : self.cached(song)
            if (best?.kind ?? .plain) < .word, let fetched = await self.fetchBest(song), fetched.kind >= (best?.kind ?? .plain) {
                best = fetched
            }
            if self.canAlign(song) {
                let duration = Double(song.durationMs) / 1000
                if let current = best, current.kind < .word {
                    if let up = try? await SpeechAligner.upgrade(current, vocals: self.paths.vocals(song.audioHash), duration: duration, languageHint: song.language) {
                        best = up
                    } else {
                        try? Data().write(to: self.alignFailedMarker(song))
                    }
                } else if best == nil {
                    best = await self.transcribe(song, duration: duration)
                }
            }
            if let current = best, let tagged = self.diarizeIfNeeded(current, song: song) { best = tagged }
            if let best { self.store(best, for: song) }
            return best
        }
    }

    /// Lyrics without singer labels: guess who sings each line from the vocal stem.
    func diarizeIfNeeded(_ lyrics: Lyrics, song: SongRecord) -> Lyrics? {
        let marker = paths.songCache(song.audioHash).appendingPathComponent("diarized")
        let model = paths.models.appendingPathComponent("ecapa.mlmodelc")
        let vocals = paths.vocals(song.audioHash)
        guard !lyrics.isDuet, !FileManager.default.fileExists(atPath: marker.path),
              FileManager.default.fileExists(atPath: model.path), FileManager.default.fileExists(atPath: vocals.path) else { return nil }
        try? Data().write(to: marker)
        guard let outcome = try? SingerDiarizer.label(lyrics, vocals: vocals, artist: song.artist, model: model), outcome.lyrics.isDuet else { return nil }
        return outcome.lyrics
    }

    /// No lyrics anywhere: write them from what is sung, one line per phrase.
    func transcribe(_ song: SongRecord, duration: TimeInterval) async -> Lyrics? {
        let lang = song.language.map { String($0.prefix(2)) } ?? "en"
        guard let words = try? await SpeechAligner.recognize(vocals: paths.vocals(song.audioHash), language: lang), words.count > 10 else { return nil }
        var lines: [LyricLine] = []
        var current: [TimedWord] = []
        func flush() {
            guard !current.isEmpty else { return }
            let segs = current.map { LyricSegment(text: $0.text, start: $0.start, end: $0.end) }
            lines.append(LyricLine(id: lines.count, start: segs[0].start, end: segs.last!.end, segments: segs))
            current = []
        }
        for w in words {
            if let last = current.last, w.start - last.end > 0.7 || current.count >= 9 { flush() }
            current.append(w)
        }
        flush()
        return Lyrics(kind: .word, source: .ai, language: lang, lines: lines)
    }

    func fetchBest(_ song: SongRecord) async -> Lyrics? {
        var candidates: [(Lyrics, Int)] = []
        let local = localCandidates(song)
        candidates += local.map { ($0, 3) }
        let best = candidates.max { $0.0.kind < $1.0.kind }
        if best?.0.kind ?? .plain < .word {
            let s = services()
            let query = LyricsQuery(title: song.title, artist: Self.primaryArtist(song.artist), album: song.album, durationMs: song.durationMs, isrc: song.isrc)
            var providers: [(any LyricsProvider, Int)] = []
            if s.singAPIEnabled, let base = URL(string: s.singAPIBase) { providers.append((SingLyricsAPI(base: base, timeout: s.timeoutSeconds), 4)) }
            if s.neteaseEnabled { providers.append((NetEaseProvider(timeout: s.timeoutSeconds), 3)) }
            if s.kugouEnabled { providers.append((KugouProvider(timeout: s.timeoutSeconds), 2)) }
            if s.lrclibEnabled { providers.append((LRCLibProvider(timeout: s.timeoutSeconds), 1)) }
            let reference = local.first { $0.kind >= .line }
            await withTaskGroup(of: (Lyrics, Int)?.self) { group in
                for (p, rank) in providers {
                    group.addTask {
                        guard let l = (try? await p.fetch(query)).flatMap({ $0 }) else { return nil }
                        return (reference.map { Self.matchTiming(l, to: $0) } ?? l, rank)
                    }
                }
                for await r in group { if let r { candidates.append(r) } }
            }
        }
        return candidates.max(by: { ($0.0.kind, $0.1) < ($1.0.kind, $1.1) })?.0
    }

    /// Providers often time a different release; shift them onto lyrics known to match this file.
    static func matchTiming(_ l: Lyrics, to reference: Lyrics) -> Lyrics {
        guard l.kind > .plain else { return l }
        var diffs: [Double] = []
        var used = Set<Int>()
        for line in l.lines {
            let key = normalizeForMatch(line.text)
            guard key.count > 6 else { continue }
            if let r = reference.lines.enumerated().filter({ !used.contains($0.offset) && normalizeForMatch($0.element.text) == key })
                .min(by: { abs($0.element.start - line.start) < abs($1.element.start - line.start) }) {
                used.insert(r.offset)
                diffs.append(r.element.start - line.start)
            }
        }
        guard diffs.count >= 3 else { return l }
        let median = diffs.sorted()[diffs.count / 2]
        return abs(median) > 0.12 && abs(median) < 30 ? l.shifted(by: median) : l
    }

    public func store(_ lyrics: Lyrics, for song: SongRecord) {
        try? FileManager.default.createDirectory(at: paths.songCache(song.audioHash), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(lyrics) { try? data.write(to: paths.lyrics(song.audioHash), options: .atomic) }
        if let id = song.id {
            let kind = lyrics.kind
            let duet = lyrics.isDuet
            Task { try? await library.update(id) { $0.lyricsKind = kind; $0.isDuet = duet } }
        }
    }

    func localCandidates(_ song: SongRecord) -> [Lyrics] {
        var out: [Lyrics] = []
        let audio = URL(fileURLWithPath: song.filePath)
        let stem = audio.deletingPathExtension()
        if let d = try? Data(contentsOf: stem.appendingPathExtension("ttml")), let l = try? TTMLParser.parse(d, source: .sidecar) { out.append(l) }
        if let t = try? String(contentsOf: stem.appendingPathExtension("lrc"), encoding: .utf8), let l = try? LRCParser.parse(t, source: .sidecar) { out.append(l) }
        let dir = paths.songCache(song.audioHash)
        if let t = try? String(contentsOf: dir.appendingPathComponent("embedded.lrc"), encoding: .utf8), let l = try? LRCParser.parse(t, source: .embedded) { out.append(l) }
        if out.isEmpty {
            for url in [stem.appendingPathExtension("txt"), dir.appendingPathComponent("embedded.txt")] {
                if let t = try? String(contentsOf: url, encoding: .utf8), let l = LRCParser.plain(t, source: .embedded) { out.append(l); break }
            }
        }
        return out
    }

    static func primaryArtist(_ artist: String) -> String {
        for sep in [" & ", ", ", " feat. ", " ft. ", ";"] {
            if let r = artist.range(of: sep) { return String(artist[..<r.lowerBound]) }
        }
        return artist
    }
}
