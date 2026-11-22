import Foundation

public struct TimedWord: Sendable, Hashable, Codable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Turns line-synced or plain lyrics into word-synced lyrics by aligning them with
/// words recognized in the vocal stem, then filling the gaps by syllable weight.
public enum LyricsAligner {
    public struct Result: Sendable {
        public var lyrics: Lyrics
        public var matchedRatio: Double
    }

    public static func align(_ lyrics: Lyrics, recognized: [TimedWord], duration: TimeInterval, language: String? = nil) -> Result {
        let timedLines = lyrics.kind >= .line
        struct Slot { var line: Int; var word: Int; var key: String; var text: String }
        var slots: [Slot] = []
        for (li, line) in lyrics.lines.enumerated() {
            for (wi, w) in line.words.enumerated() {
                let text = w.map(\.text).joined()
                slots.append(Slot(line: li, word: wi, key: normalizeForMatch(text), text: text))
            }
        }
        let rec = recognized.filter { !normalizeForMatch($0.text).isEmpty }
        let recKeys = rec.map { normalizeForMatch($0.text) }
        let n = slots.count, m = rec.count
        guard n > 0 else { return Result(lyrics: lyrics, matchedRatio: 0) }

        func window(_ s: Slot) -> ClosedRange<TimeInterval>? {
            guard timedLines else { return nil }
            let l = lyrics.lines[s.line]
            let nextStart = s.line + 1 < lyrics.lines.count ? lyrics.lines[s.line + 1].start : duration
            return (l.start - 1.2)...(max(l.end, nextStart) + 0.8)
        }

        let gap = -0.45
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var move = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { score[i][0] = Double(i) * gap; move[i][0] = 1 }
        if m > 0 { for j in 1...m { score[0][j] = Double(j) * gap * 0.5; move[0][j] = 2 } }
        if m > 0 {
            for i in 1...n {
                let s = slots[i - 1]
                let w = window(s)
                for j in 1...m {
                    var matchScore = -1.0
                    if w == nil || w!.contains(rec[j - 1].start) {
                        let sim = s.key == recKeys[j - 1] ? 1 : wordSimilarity(s.key, recKeys[j - 1])
                        matchScore = sim >= 0.6 ? 2 * sim : -1
                    }
                    let diag = score[i - 1][j - 1] + matchScore
                    let up = score[i - 1][j] + gap
                    let left = score[i][j - 1] + gap * 0.5
                    if diag >= up && diag >= left { score[i][j] = diag; move[i][j] = 0 } else if up >= left { score[i][j] = up; move[i][j] = 1 } else { score[i][j] = left; move[i][j] = 2 }
                }
            }
        }
        var anchor = [TimedWord?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, move[i][j] == 0 {
                let s = slots[i - 1]
                let sim = s.key == recKeys[j - 1] ? 1 : wordSimilarity(s.key, recKeys[j - 1])
                if sim >= 0.6 { anchor[i - 1] = rec[j - 1] }
                i -= 1; j -= 1
            } else if i > 0, j == 0 || move[i][j] == 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        let matched = anchor.compactMap { $0 }.count

        var starts = [TimeInterval](repeating: 0, count: n)
        var ends = [TimeInterval](repeating: 0, count: n)
        var k = 0
        while k < n {
            if let a = anchor[k] {
                starts[k] = a.start
                ends[k] = a.end
                k += 1
                continue
            }
            var e = k
            while e < n, anchor[e] == nil { e += 1 }
            let prevEnd = k > 0 ? ends[k - 1] : (timedLines ? lyrics.lines[slots[k].line].start : 0)
            let nextStart = e < n ? anchor[e]!.start : duration
            fillRun(k..<e, slots.map(\.text), slots.map(\.line), lyrics: lyrics, timedLines: timedLines, from: prevEnd, to: nextStart, starts: &starts, ends: &ends)
            k = e
        }
        for x in 0..<n {
            if x > 0, starts[x] < starts[x - 1] { starts[x] = starts[x - 1] }
            let limit = x + 1 < n ? starts[x + 1] : duration
            ends[x] = max(starts[x] + 0.08, min(ends[x], limit, starts[x] + 2.5))
        }

        var lines = lyrics.lines
        var idx = 0
        var anySyllables = false
        for li in lines.indices {
            let words = lines[li].words
            var segs: [LyricSegment] = []
            var heard = 0
            for w in words {
                // A word given as one piece is split into syllables with the language's hyphenation rules.
                let pieces: [String] = w.count == 1 ? Hyphenator.syllables(w[0].text, language: language ?? lyrics.language) : w.map(\.text)
                if pieces.count > 1 { anySyllables = true }
                let weights = pieces.map { Double(max(1, Hyphenator.vowelWeight($0))) }
                let total = weights.reduce(0, +)
                var t = starts[idx]
                let span = ends[idx] - starts[idx]
                for (si, s) in pieces.enumerated() {
                    let d = span * weights[si] / total
                    segs.append(LyricSegment(text: s, start: t, end: t + d, endsWord: si == pieces.count - 1))
                    t += d
                }
                if anchor[idx] != nil { heard += 1 }
                idx += 1
            }
            guard !segs.isEmpty else { continue }
            lines[li].segments = segs
            lines[li].start = segs[0].start
            lines[li].end = segs.last!.end
            lines[li].confidence = words.isEmpty ? nil : 0.35 + 0.65 * Double(heard) / Double(words.count)
        }
        var out = lyrics
        out.lines = lines
        out.kind = anySyllables ? .syllable : (lyrics.kind >= .word ? lyrics.kind : .word)
        out.source = .ai
        out.model = "apple-speech + sing-aligner/2"
        out.needsReview = Double(matched) / Double(n) < 0.6 || lines.contains { ($0.confidence ?? 1) < 0.45 && $0.segments.count > 2 }
        return Result(lyrics: out, matchedRatio: Double(matched) / Double(n))
    }

    private static func fillRun(_ run: Range<Int>, _ texts: [String], _ lineOf: [Int], lyrics: Lyrics, timedLines: Bool, from: TimeInterval, to: TimeInterval, starts: inout [TimeInterval], ends: inout [TimeInterval]) {
        var groups: [(line: Int, idx: [Int])] = []
        for x in run {
            if groups.last?.line == lineOf[x] { groups[groups.count - 1].idx.append(x) } else { groups.append((lineOf[x], [x])) }
        }
        var cursor = from
        for (gi, g) in groups.enumerated() {
            var lo = cursor, hi = to
            if timedLines {
                let l = lyrics.lines[g.line]
                lo = max(cursor, l.start)
                let natural = g.idx.reduce(0.0) { $0 + Double(WordTimingEstimator.syllableCount(texts[$1])) * 0.3 } + 0.3
                hi = min(to, max(lo + 0.3, gi == groups.count - 1 ? min(l.end, lo + natural * 1.4) : l.end))
                if hi <= lo { hi = lo + 0.3 }
            } else {
                let remaining = groups[gi...].reduce(0) { $0 + $1.idx.count }
                hi = lo + (to - lo) * Double(g.idx.count) / Double(max(remaining, 1))
            }
            let words = g.idx.map { texts[$0] }
            let segs = WordTimingEstimator.segments(words: words, start: lo, end: hi)
            for (k, x) in g.idx.enumerated() {
                starts[x] = segs[k].start
                ends[x] = segs[k].end
            }
            cursor = hi
        }
    }

    static func wordSimilarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let d = levenshtein(Array(a), Array(b))
        return 1 - Double(d) / Double(max(a.count, b.count))
    }
}
