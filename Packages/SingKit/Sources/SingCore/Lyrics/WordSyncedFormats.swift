import Foundation

/// NetEase YRC (`[lineStart,lineDur](wordStart,wordDur,0)word`, absolute ms) and
/// Kugou KRC (`[lineStart,lineDur]<offset,dur,0>word`, offsets relative to the line).
public enum WordSyncedParser {
    public static func parseYRC(_ text: String, source: LyricsSource) -> Lyrics? {
        parse(text, open: "(", close: ")", relative: false, source: source)
    }

    public static func parseKRC(_ text: String, source: LyricsSource) -> Lyrics? {
        parse(text, open: "<", close: ">", relative: true, source: source)
    }

    static let creditMarkers = ["作词", "作曲", "编曲", "制作", "词：", "曲：", "produced by", "lyrics by", "composed by", "written by", "arranged by", "mixed by"]

    static func isCredit(_ s: String) -> Bool {
        let l = s.lowercased()
        return creditMarkers.contains { l.contains($0) } || (l.contains("：") && l.count < 80)
    }

    static func parse(_ text: String, open: Character, close: Character, relative: Bool, source: LyricsSource) -> Lyrics? {
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let row = raw.trimmingCharacters(in: .whitespaces)
            guard row.hasPrefix("["), let headEnd = row.firstIndex(of: "]") else { continue }
            let head = row[row.index(after: row.startIndex)..<headEnd].split(separator: ",")
            guard head.count >= 2, let ls = Double(head[0]), let ld = Double(head[1]) else { continue }
            var rest = row[row.index(after: headEnd)...]
            var segments: [LyricSegment] = []
            while let o = rest.firstIndex(of: open), let c = rest[o...].firstIndex(of: close) {
                let nums = rest[rest.index(after: o)..<c].split(separator: ",").compactMap { Double($0) }
                rest = rest[rest.index(after: c)...]
                let textEnd = rest.firstIndex(of: open) ?? rest.endIndex
                let word = String(rest[..<textEnd])
                rest = rest[textEnd...]
                guard nums.count >= 2 else { continue }
                let start = (relative ? ls + nums[0] : nums[0]) / 1000
                let end = start + nums[1] / 1000
                let core = word.trimmingCharacters(in: .whitespaces)
                if core.isEmpty {
                    if !segments.isEmpty { segments[segments.count - 1].endsWord = true }
                    continue
                }
                if word.first?.isWhitespace == true, !segments.isEmpty { segments[segments.count - 1].endsWord = true }
                segments.append(LyricSegment(text: core, start: start, end: end, endsWord: word.last?.isWhitespace == true))
            }
            guard !segments.isEmpty else { continue }
            segments[segments.count - 1].endsWord = true
            let line = LyricLine(id: lines.count, start: ls / 1000, end: max((ls + ld) / 1000, segments.last!.end), segments: segments)
            if lines.count < 6, isCredit(line.text) { continue }
            lines.append(line)
        }
        guard lines.count >= 3 else { return nil }
        lines.sort { $0.start < $1.start }
        for i in lines.indices { lines[i].id = i }
        let syllables = lines.contains { $0.words.contains { $0.count > 1 } }
        return Lyrics(kind: syllables ? .syllable : .word, source: source, lines: lines)
    }

    /// Kugou's KRC payload: base64, a 4-byte header, XOR with a fixed key, then zlib.
    public static func decodeKRC(base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), data.count > 4 else { return nil }
        let key: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]
        let body = [UInt8](data.dropFirst(4)).enumerated().map { $0.element ^ key[$0.offset % 16] }
        guard let inflated = Zlib.inflate(Data(body)) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }
}

enum Zlib {
    static func inflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let raw = data.dropFirst(2)
        return try? (raw as NSData).decompressed(using: .zlib) as Data
    }
}

func similarity(_ a: String, _ b: String) -> Double {
    let x = normalizeForMatch(a), y = normalizeForMatch(b)
    if x == y { return 1 }
    if x.contains(y) || y.contains(x) { return 0.85 }
    let d = levenshtein(Array(x), Array(y))
    return 1 - Double(d) / Double(max(x.count, y.count, 1))
}

public func normalizeForMatch(_ s: String) -> String {
    var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    for cut in [" (", " [", " - ", " feat", " ft."] {
        if let r = t.range(of: cut) { t = String(t[..<r.lowerBound]) }
    }
    return t.filter { $0.isLetter || $0.isNumber }
}

func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    for i in 1...a.count {
        var cur = [i] + Array(repeating: 0, count: b.count)
        for j in 1...b.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return prev[b.count]
}

public struct NetEaseProvider: LyricsProvider {
    public let name = "NetEase"
    let session: URLSession

    public init(timeout: TimeInterval = 6) { session = makeSession(timeout: timeout) }

    struct SearchResult: Decodable {
        struct R: Decodable { var songs: [Song]? }
        struct Song: Decodable {
            var id: Int
            var name: String
            var ar: [Artist]?
            var dt: Int?
        }
        struct Artist: Decodable { var name: String }
        var result: R?
    }

    struct LyricResult: Decodable {
        struct L: Decodable { var lyric: String? }
        var yrc: L?
        var lrc: L?
    }

    public func fetch(_ q: LyricsQuery) async throws -> Lyrics? {
        var c = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")!
        c.queryItems = [URLQueryItem(name: "s", value: "\(q.title) \(q.artist)"), URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "limit", value: "10")]
        let (data, _) = try await session.data(from: c.url!)
        let songs = (try JSONDecoder().decode(SearchResult.self, from: data)).result?.songs ?? []
        let ranked = songs.filter { s in
            let durOK = q.durationMs == 0 || abs((s.dt ?? 0) - q.durationMs) < 6000
            let titleOK = similarity(s.name, q.title) > 0.7
            let lower = s.name.lowercased()
            let clean = !["instrumental", "karaoke", "remix", "dub", "live", "伴奏"].contains { lower.contains($0) && !q.title.lowercased().contains($0) }
            return durOK && titleOK && clean
        }.sorted { abs(($0.dt ?? 0) - q.durationMs) < abs(($1.dt ?? 0) - q.durationMs) }
        var fallback: Lyrics?
        for s in ranked.prefix(4) {
            let u = URL(string: "https://music.163.com/api/song/lyric/v1?id=\(s.id)&lv=-1&kv=-1&tv=-1&rv=-1&yv=-1&ytv=-1&yrv=-1")!
            let (ld, _) = try await session.data(from: u)
            guard let lr = try? JSONDecoder().decode(LyricResult.self, from: ld) else { continue }
            if let y = lr.yrc?.lyric, let l = WordSyncedParser.parseYRC(y, source: .netease) { return l }
            if fallback == nil, let lrc = lr.lrc?.lyric { fallback = try? LRCParser.parse(lrc, source: .netease) }
        }
        return fallback
    }
}

public struct KugouProvider: LyricsProvider {
    public let name = "Kugou"
    let session: URLSession

    public init(timeout: TimeInterval = 6) { session = makeSession(timeout: timeout) }

    struct Search: Decodable {
        struct Candidate: Decodable {
            var id: String
            var accesskey: String
            var song: String?
            var duration: Int?
        }
        var candidates: [Candidate]?
    }

    struct Download: Decodable { var content: String? }

    public func fetch(_ q: LyricsQuery) async throws -> Lyrics? {
        var candidates: [Search.Candidate] = []
        for keyword in ["\(q.artist) - \(q.title)", q.title] where candidates.isEmpty {
            var c = URLComponents(string: "https://lyrics.kugou.com/search")!
            c.queryItems = [
                URLQueryItem(name: "ver", value: "1"), URLQueryItem(name: "man", value: "yes"), URLQueryItem(name: "client", value: "pc"),
                URLQueryItem(name: "keyword", value: keyword), URLQueryItem(name: "duration", value: String(q.durationMs)), URLQueryItem(name: "hash", value: ""),
            ]
            let (data, _) = try await session.data(from: c.url!)
            candidates = (try? JSONDecoder().decode(Search.self, from: data))?.candidates ?? []
            candidates = candidates.filter { c in
                (q.durationMs == 0 || abs((c.duration ?? q.durationMs) - q.durationMs) < 6000) && similarity(c.song ?? q.title, q.title) > 0.6
            }
        }
        for cand in candidates.prefix(3) {
            let u = URL(string: "https://lyrics.kugou.com/download?ver=1&client=pc&id=\(cand.id)&accesskey=\(cand.accesskey)&fmt=krc&charset=utf8")!
            let (data, _) = try await session.data(from: u)
            guard let content = (try? JSONDecoder().decode(Download.self, from: data))?.content,
                  let text = WordSyncedParser.decodeKRC(base64: content),
                  let lyrics = WordSyncedParser.parseKRC(text, source: .kugou) else { continue }
            return lyrics
        }
        return nil
    }
}
