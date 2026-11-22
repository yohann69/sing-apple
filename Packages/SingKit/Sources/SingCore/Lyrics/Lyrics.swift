import Foundation

public enum LyricsKind: String, Codable, Sendable, Comparable, CaseIterable {
    case plain
    case line
    case word
    case syllable

    private var rank: Int {
        switch self {
        case .plain: 0
        case .line: 1
        case .word: 2
        case .syllable: 3
        }
    }

    public static func < (lhs: LyricsKind, rhs: LyricsKind) -> Bool { lhs.rank < rhs.rank }
}

public enum LyricsSource: String, Codable, Sendable {
    case singAPI
    case lrclib
    case netease
    case kugou
    case qq
    case musixmatch
    case embedded
    case sidecar
    case ai
    case manual
}

/// A timed piece of a line. A word is one or more segments; `endsWord` marks a space after it.
public struct LyricSegment: Codable, Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var endsWord: Bool

    public init(text: String, start: TimeInterval, end: TimeInterval, endsWord: Bool = true) {
        self.text = text
        self.start = start
        self.end = end
        self.endsWord = endsWord
    }
}

public struct LyricLine: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var agent: String?
    public var segments: [LyricSegment]
    public var background: [LyricSegment]
    public var translation: String?
    public var romanization: String?
    /// 0 to 1: how sure the AI timing is for this line (1 when heard, lower when estimated).
    public var confidence: Double?

    public init(id: Int, start: TimeInterval, end: TimeInterval, agent: String? = nil, segments: [LyricSegment], background: [LyricSegment] = [], translation: String? = nil, romanization: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.agent = agent
        self.segments = segments
        self.background = background
        self.translation = translation
        self.romanization = romanization
    }

    public var text: String { Self.join(segments) }
    public var backgroundText: String { Self.join(background) }

    static func join(_ segments: [LyricSegment]) -> String {
        var out = ""
        for (i, s) in segments.enumerated() {
            out += s.text
            if s.endsWord && i < segments.count - 1 { out += " " }
        }
        return out
    }

    /// Words built from segments, each holding its syllable segments.
    public var words: [[LyricSegment]] {
        var result: [[LyricSegment]] = []
        var current: [LyricSegment] = []
        for s in segments {
            current.append(s)
            if s.endsWord {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

public struct Agent: Codable, Sendable, Hashable {
    public var id: String
    public var name: String?
    public var isGroup: Bool

    public init(id: String, name: String? = nil, isGroup: Bool = false) {
        self.id = id
        self.name = name
        self.isGroup = isGroup
    }
}

public struct Lyrics: Codable, Sendable, Hashable {
    public var kind: LyricsKind
    public var source: LyricsSource
    public var language: String?
    public var agents: [Agent]
    public var lines: [LyricLine]
    /// AI timing that should be checked by a person before it is shared.
    public var needsReview: Bool?
    /// What produced the timing, like "apple-speech/26 + sing-aligner/2".
    public var model: String?

    public init(kind: LyricsKind, source: LyricsSource, language: String? = nil, agents: [Agent] = [], lines: [LyricLine]) {
        self.kind = kind
        self.source = source
        self.language = language
        self.agents = agents
        self.lines = lines
    }

    public var isDuet: Bool {
        Set(lines.compactMap(\.agent)).subtracting(agents.filter(\.isGroup).map(\.id)).count >= 2
    }

    public func lineIndex(at time: TimeInterval) -> Int? {
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= time {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }

    public func shifted(by offset: TimeInterval) -> Lyrics {
        var copy = self
        copy.lines = lines.map { line in
            var l = line
            l.start += offset
            l.end += offset
            l.segments = l.segments.map { var s = $0; s.start += offset; s.end += offset; return s }
            l.background = l.background.map { var s = $0; s.start += offset; s.end += offset; return s }
            return l
        }
        return copy
    }
}

extension Lyrics {
    /// Fills `romanization` for lines written in a non-Latin script (Japanese, Chinese, Korean, Cyrillic, Greek…).
    public func romanized() -> Lyrics {
        var copy = self
        for i in copy.lines.indices where copy.lines[i].romanization == nil {
            let text = copy.lines[i].text
            guard text.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.value > 0x24F }) else { continue }
            let m = NSMutableString(string: text)
            CFStringTransform(m, nil, kCFStringTransformToLatin, false)
            CFStringTransform(m, nil, kCFStringTransformStripCombiningMarks, false)
            let out = (m as String).trimmingCharacters(in: .whitespaces)
            if out != text, !out.isEmpty { copy.lines[i].romanization = out }
        }
        return copy
    }
}
