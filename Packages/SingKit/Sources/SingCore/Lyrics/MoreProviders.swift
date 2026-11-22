import Foundation

extension WordSyncedParser {
    /// QQ Music QRC (after decryption): `[lineStart,lineDur]word(start,dur)word(start,dur)…`, absolute ms.
    public static func parseQRC(_ text: String, source: LyricsSource) -> Lyrics? {
        let body = text.range(of: "LyricContent=\"").map { String(text[$0.upperBound...].prefix { $0 != "\"" }) } ?? text
        var lines: [LyricLine] = []
        let wordRegex = try! NSRegularExpression(pattern: #"([^()]*)\((\d+),(\d+)\)"#)
        for raw in body.components(separatedBy: .newlines) {
            guard let close = raw.firstIndex(of: "]"), raw.hasPrefix("["),
                  raw[raw.index(after: raw.startIndex)..<close].contains(",") else { continue }
            let rest = String(raw[raw.index(after: close)...])
            let ns = rest as NSString
            var segs: [LyricSegment] = []
            for m in wordRegex.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: m.range(at: 1))
                guard !word.isEmpty, let s = Double(ns.substring(with: m.range(at: 2))), let d = Double(ns.substring(with: m.range(at: 3))) else { continue }
                let endsWord = word.hasSuffix(" ") || !word.unicodeScalars.contains { CharacterSet.letters.contains($0) && $0.value < 0x2E80 }
                segs.append(LyricSegment(text: word.trimmingCharacters(in: .whitespaces) + (endsWord ? " " : ""), start: s / 1000, end: (s + d) / 1000, endsWord: endsWord))
            }
            guard !segs.isEmpty else { continue }
            if let last = segs.indices.last { segs[last].endsWord = true }
            let text = segs.map(\.text).joined()
            if isCredit(text) { continue }
            lines.append(LyricLine(id: lines.count, start: segs[0].start, end: segs.last!.end, segments: segs))
        }
        guard lines.count >= 3 else { return nil }
        let syllables = lines.contains { $0.words.contains { $0.count > 1 } }
        return Lyrics(kind: syllables ? .syllable : .word, source: source, lines: lines)
    }

    /// Musixmatch richsync JSON: `[{"ts":12.1,"te":14.2,"x":"line","l":[{"c":"word","o":0.0}]}]`.
    public static func parseMusixmatchRichsync(_ json: String, source: LyricsSource = .musixmatch) -> Lyrics? {
        struct Line: Decodable { struct C: Decodable { var c: String; var o: Double }; var ts: Double; var te: Double; var l: [C] }
        guard let rows = try? JSONDecoder().decode([Line].self, from: Data(json.utf8)), !rows.isEmpty else { return nil }
        var lines: [LyricLine] = []
        for r in rows {
            let chars = r.l.filter { !$0.c.isEmpty }
            var segs: [LyricSegment] = []
            var word = "", wordStart: Double?
            for (i, c) in chars.enumerated() {
                if c.c == " " {
                    if let ws = wordStart, !word.isEmpty { segs.append(LyricSegment(text: word + " ", start: r.ts + ws, end: r.ts + c.o, endsWord: true)) }
                    word = ""; wordStart = nil
                    continue
                }
                if wordStart == nil { wordStart = c.o }
                word += c.c
                if i == chars.count - 1, let ws = wordStart { segs.append(LyricSegment(text: word, start: r.ts + ws, end: r.te, endsWord: true)) }
            }
            guard !segs.isEmpty else { continue }
            for k in segs.indices.dropLast() where segs[k].end <= segs[k].start { segs[k].end = segs[k + 1].start }
            lines.append(LyricLine(id: lines.count, start: r.ts, end: r.te, segments: segs))
        }
        return lines.isEmpty ? nil : Lyrics(kind: .word, source: source, lines: lines)
    }

    /// Musixmatch subtitle JSON: `[{"text":"line","time":{"total":12.3}}]`, line timing.
    public static func parseMusixmatchSubtitles(_ json: String) -> Lyrics? {
        struct Row: Decodable { struct T: Decodable { var total: Double }; var text: String; var time: T }
        guard let rows = try? JSONDecoder().decode([Row].self, from: Data(json.utf8)) else { return nil }
        let lrc = rows.filter { !$0.text.isEmpty }.map { r -> String in
            let m = Int(r.time.total) / 60
            return String(format: "[%02d:%05.2f]%@", m, r.time.total - Double(m * 60), r.text)
        }.joined(separator: "\n")
        return try? LRCParser.parse(lrc, source: .musixmatch)
    }
}

/// QQ Music: search, then the line-synced lyric (QRC word timing is encrypted and only used when given decrypted).
public struct QQMusicProvider: LyricsProvider {
    public let name = "QQ Music"
    let session: URLSession

    public init(timeout: TimeInterval = 6) { session = makeSession(timeout: timeout) }

    struct Search: Decodable {
        struct D: Decodable { struct S: Decodable { var list: [Song]? }; var song: S? }
        struct Song: Decodable { struct Singer: Decodable { var name: String }; var songmid: String; var songname: String; var singer: [Singer]?; var interval: Int? }
        var data: D?
    }
    struct Lyric: Decodable { var lyric: String? }

    public func fetch(_ q: LyricsQuery) async throws -> Lyrics? {
        var c = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
        c.queryItems = [URLQueryItem(name: "w", value: "\(q.title) \(q.artist)"), URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "p", value: "1"), URLQueryItem(name: "n", value: "8")]
        var req = URLRequest(url: c.url!)
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: req)
        let songs = (try? JSONDecoder().decode(Search.self, from: data))?.data?.song?.list ?? []
        let ranked = songs.filter { s in
            similarity(s.songname, q.title) > 0.7 && (q.durationMs == 0 || abs((s.interval ?? 0) * 1000 - q.durationMs) < 6000)
        }
        for s in ranked.prefix(3) {
            var lc = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
            lc.queryItems = [URLQueryItem(name: "songmid", value: s.songmid), URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "nobase64", value: "1"), URLQueryItem(name: "g_tk", value: "5381")]
            var lr = URLRequest(url: lc.url!)
            lr.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            guard let (ld, _) = try? await session.data(for: lr), let text = (try? JSONDecoder().decode(Lyric.self, from: ld))?.lyric else { continue }
            let decoded = text.replacingOccurrences(of: "&#58;", with: ":").replacingOccurrences(of: "&#46;", with: ".").replacingOccurrences(of: "&#32;", with: " ")
                .replacingOccurrences(of: "&#10;", with: "\n").replacingOccurrences(of: "&#45;", with: "-").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&#40;", with: "(").replacingOccurrences(of: "&#41;", with: ")")
            if let l = try? LRCParser.parse(decoded, source: .qq), l.lines.count >= 3 { return l }
        }
        return nil
    }
}

/// Musixmatch's desktop app endpoints: word-synced "richsync" when available, else line-synced subtitles.
public actor MusixmatchProvider: LyricsProvider {
    public nonisolated let name = "Musixmatch"
    let session: URLSession
    var token: String?
    static let base = "https://apic-desktop.musixmatch.com/ws/1.1/"

    public init(timeout: TimeInterval = 6) { session = makeSession(timeout: timeout) }

    func call(_ method: String, _ items: [URLQueryItem]) async throws -> [String: Any]? {
        var c = URLComponents(string: Self.base + method)!
        c.queryItems = items + [URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0"), URLQueryItem(name: "format", value: "json")] + (token.map { [URLQueryItem(name: "usertoken", value: $0)] } ?? [])
        var req = URLRequest(url: c.url!)
        req.setValue("x-mxm-token-guid=", forHTTPHeaderField: "Cookie")
        let (d, _) = try await session.data(for: req)
        guard let root = try JSONSerialization.jsonObject(with: d) as? [String: Any], let msg = root["message"] as? [String: Any],
              let header = msg["header"] as? [String: Any], header["status_code"] as? Int == 200 else { return nil }
        return msg["body"] as? [String: Any]
    }

    public func fetch(_ q: LyricsQuery) async throws -> Lyrics? {
        if token == nil { token = (try await call("token.get", []))?["user_token"] as? String }
        guard let t = token, !t.contains("UpgradeOnly") else { token = nil; return nil }
        var items = [URLQueryItem(name: "q_track", value: q.title), URLQueryItem(name: "q_artist", value: q.artist)]
        if q.durationMs > 0 { items.append(URLQueryItem(name: "q_duration", value: String(q.durationMs / 1000))) }
        if let isrc = q.isrc { items.append(URLQueryItem(name: "track_isrc", value: isrc)) }
        guard let match = try await call("matcher.track.get", items), let track = match["track"] as? [String: Any], let id = track["track_id"] as? Int else { return nil }
        if (track["has_richsync"] as? Int) == 1, let rs = try await call("track.richsync.get", [URLQueryItem(name: "track_id", value: String(id))]),
           let body = (rs["richsync"] as? [String: Any])?["richsync_body"] as? String, let l = WordSyncedParser.parseMusixmatchRichsync(body) {
            return l
        }
        if let sub = try await call("track.subtitle.get", [URLQueryItem(name: "track_id", value: String(id)), URLQueryItem(name: "subtitle_format", value: "mxm")]),
           let body = (sub["subtitle"] as? [String: Any])?["subtitle_body"] as? String {
            return WordSyncedParser.parseMusixmatchSubtitles(body)
        }
        return nil
    }
}
