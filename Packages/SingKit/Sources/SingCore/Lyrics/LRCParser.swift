import Foundation

public enum LRCParser {
    /// Parses LRC and enhanced LRC (`<mm:ss.xx>` word stamps). Lines without stamps are dropped.
    public static func parse(_ text: String, source: LyricsSource) throws -> Lyrics {
        var offset: TimeInterval = 0
        var raw: [(TimeInterval, String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var stamps: [TimeInterval] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex)..<close]
                if let t = parseStamp(tag) {
                    stamps.append(t)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
                line = line[line.index(after: close)...]
            }
            for s in stamps { raw.append((s, String(line))) }
        }
        raw.sort { $0.0 < $1.0 }
        guard !raw.isEmpty else { throw LyricsParseError.empty }

        var lines: [LyricLine] = []
        var anyWordStamps = false
        for (i, item) in raw.enumerated() {
            let start = item.0 - offset
            let nextStart = i + 1 < raw.count ? raw[i + 1].0 - offset : start + 6
            let body = item.1.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            if let segments = enhancedSegments(body, lineStart: start, lineEnd: nextStart, offset: offset) {
                anyWordStamps = true
                lines.append(LyricLine(id: lines.count, start: start, end: segments.last?.end ?? nextStart, segments: segments))
            } else {
                let words = body.split(whereSeparator: \.isWhitespace).map(String.init)
                let end = WordTimingEstimator.naturalEnd(words: words, start: start, nextStart: nextStart)
                let segments = WordTimingEstimator.segments(words: words, start: start, end: end)
                lines.append(LyricLine(id: lines.count, start: start, end: end, segments: segments))
            }
        }
        guard !lines.isEmpty else { throw LyricsParseError.empty }
        return Lyrics(kind: anyWordStamps ? .word : .line, source: source, lines: lines)
    }

    public static func plain(_ text: String, source: LyricsSource) -> Lyrics? {
        let rows = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }
        let lines = rows.enumerated().map { i, row in
            LyricLine(id: i, start: 0, end: 0, segments: row.split(whereSeparator: \.isWhitespace).map { LyricSegment(text: String($0), start: 0, end: 0) })
        }
        return Lyrics(kind: .plain, source: source, lines: lines)
    }

    static func parseStamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for p in parts {
            guard let n = Double(p.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + n
        }
        return total
    }

    private static func enhancedSegments(_ body: String, lineStart: TimeInterval, lineEnd: TimeInterval, offset: TimeInterval) -> [LyricSegment]? {
        guard body.contains("<") else { return nil }
        var pieces: [(TimeInterval, String)] = []
        var rest = Substring(body)
        var pendingText = ""
        var currentStart = lineStart
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            pendingText += rest[..<open]
            if let t = parseStamp(rest[rest.index(after: open)..<close]) {
                if !pendingText.isEmpty { pieces.append((currentStart, pendingText)) }
                pendingText = ""
                currentStart = t - offset
            }
            rest = rest[rest.index(after: close)...]
        }
        pendingText += rest
        var trailingEnd: TimeInterval?
        if !pendingText.trimmingCharacters(in: .whitespaces).isEmpty {
            pieces.append((currentStart, pendingText))
        } else if let last = pieces.last, currentStart > last.0 {
            trailingEnd = currentStart
        }
        guard pieces.count > 1 || (pieces.count == 1 && trailingEnd != nil) else { return nil }
        var segments: [LyricSegment] = []
        for (i, p) in pieces.enumerated() {
            let trimmed = p.1.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                if !segments.isEmpty { segments[segments.count - 1].endsWord = true }
                continue
            }
            let end = i + 1 < pieces.count ? pieces[i + 1].0 : (trailingEnd ?? min(lineEnd, p.0 + 1.2))
            let endsWord = p.1.last?.isWhitespace ?? true || i == pieces.count - 1
            segments.append(LyricSegment(text: trimmed, start: p.0, end: end, endsWord: endsWord))
        }
        return segments.isEmpty ? nil : segments
    }
}

public enum WordTimingEstimator {
    static let secondsPerSyllable = 0.28

    public static func syllableCount(_ word: String) -> Int {
        let vowels = Set("aeiouyàâäéèêëîïôöùûüœæAEIOUYÀÂÄÉÈÊËÎÏÔÖÙÛÜ")
        var count = 0
        var inVowel = false
        for c in word {
            let v = vowels.contains(c)
            if v && !inVowel { count += 1 }
            inVowel = v
        }
        return max(1, count)
    }

    public static func naturalEnd(words: [String], start: TimeInterval, nextStart: TimeInterval) -> TimeInterval {
        let syllables = words.reduce(0) { $0 + syllableCount($1) }
        let natural = Double(syllables) * secondsPerSyllable * 1.35 + 0.4
        let gap = nextStart - start
        return start + max(0.3, gap > 8 ? min(gap, natural) : gap)
    }

    public static func segments(words: [String], start: TimeInterval, end: TimeInterval) -> [LyricSegment] {
        let weights = words.map { Double(syllableCount($0)) + Double($0.count) * 0.08 }
        let total = max(weights.reduce(0, +), 0.001)
        var t = start
        return zip(words, weights).map { word, w in
            let d = (end - start) * w / total
            defer { t += d }
            return LyricSegment(text: word, start: t, end: t + d)
        }
    }
}
