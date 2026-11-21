import Foundation

public enum LyricsParseError: Error, Equatable {
    case malformed(String)
    case empty
}

public enum TTMLParser {
    public static func parse(_ data: Data, source: LyricsSource = .singAPI) throws -> Lyrics {
        let root = try XMLTreeBuilder.parse(data)
        guard root.localName == "tt" else { throw LyricsParseError.malformed("root is not <tt>") }
        let language = root.attr("lang")

        var agents: [Agent] = []
        for a in root.all("agent") where a.parent?.localName != "p" {
            guard let id = a.attr("id") else { continue }
            let name = a.first("name")?.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            agents.append(Agent(id: id, name: name?.isEmpty == false ? name : nil, isGroup: a.attr("type") == "group"))
        }

        let translations = metadataTexts(root, container: "translation")
        let romanizations = metadataTexts(root, container: "transliteration")

        guard let body = root.first("body") else { throw LyricsParseError.malformed("no <body>") }
        var lines: [LyricLine] = []
        var hasSegmentTiming = false
        var hasSyllables = false

        for p in body.all("p") {
            guard let pStart = p.attr("begin").flatMap(parseTime) else { continue }
            let pEnd = p.attr("end").flatMap(parseTime) ?? pStart
            var collector = SegmentCollector()
            var bg = SegmentCollector()
            var translation: String?
            var romanization: String?
            walk(p, into: &collector, background: &bg, translation: &translation, romanization: &romanization, inherited: (pStart, pEnd))
            collector.finish()
            bg.finish()
            guard !collector.segments.isEmpty || !bg.segments.isEmpty else { continue }
            if collector.timed { hasSegmentTiming = true }
            let line = LyricLine(
                id: lines.count,
                start: pStart,
                end: max(pEnd, collector.segments.last?.end ?? pEnd),
                agent: p.attr("agent"),
                segments: collector.segments,
                background: bg.segments,
                translation: translation ?? p.attr("key").flatMap { translations[$0] },
                romanization: romanization ?? p.attr("key").flatMap { romanizations[$0] }
            )
            if line.words.contains(where: { $0.count > 1 }) { hasSyllables = true }
            lines.append(line)
        }
        guard !lines.isEmpty else { throw LyricsParseError.empty }
        lines.sort { $0.start < $1.start }
        for i in lines.indices { lines[i].id = i }
        let kind: LyricsKind = hasSegmentTiming ? (hasSyllables ? .syllable : .word) : .line
        return Lyrics(kind: kind, source: source, language: language, agents: agents, lines: lines)
    }

    private struct SegmentCollector {
        var segments: [LyricSegment] = []
        var timed = false

        mutating func add(_ text: String, start: TimeInterval, end: TimeInterval, timed: Bool) {
            let trimmedLeading = text.drop(while: \.isWhitespace)
            if trimmedLeading.count != text.count, !segments.isEmpty { segments[segments.count - 1].endsWord = true }
            let core = trimmedLeading.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty else { return }
            if timed { self.timed = true }
            let endsWord = text.last?.isWhitespace ?? false
            if !timed {
                for word in core.split(whereSeparator: \.isWhitespace) {
                    segments.append(LyricSegment(text: String(word), start: start, end: end, endsWord: true))
                }
                return
            }
            segments.append(LyricSegment(text: core, start: start, end: end, endsWord: endsWord))
        }

        mutating func space() {
            if !segments.isEmpty { segments[segments.count - 1].endsWord = true }
        }

        mutating func finish() {
            if !segments.isEmpty { segments[segments.count - 1].endsWord = true }
        }
    }

    private static func walk(_ node: XMLNode, into collector: inout SegmentCollector, background: inout SegmentCollector, translation: inout String?, romanization: inout String?, inherited: (TimeInterval, TimeInterval)) {
        for child in node.children {
            switch child {
            case .text(let t):
                if t.allSatisfy(\.isWhitespace) {
                    collector.space()
                } else {
                    collector.add(t, start: inherited.0, end: inherited.1, timed: false)
                }
            case .element(let e):
                guard e.localName == "span" else { continue }
                let role = e.attr("role")
                if role == "x-bg" {
                    var nestedTranslation: String?
                    var nestedRoman: String?
                    var dummy = SegmentCollector()
                    walk(e, into: &background, background: &dummy, translation: &nestedTranslation, romanization: &nestedRoman, inherited: times(e, inherited))
                    background.space()
                    continue
                }
                if role == "x-translation" {
                    translation = e.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }
                if role == "x-roman" {
                    romanization = e.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }
                if e.elements.contains(where: { $0.localName == "span" }) {
                    walk(e, into: &collector, background: &background, translation: &translation, romanization: &romanization, inherited: times(e, inherited))
                } else {
                    let (s, en) = times(e, inherited)
                    collector.add(e.textContent, start: s, end: en, timed: e.attr("begin") != nil)
                }
            }
        }
    }

    private static func times(_ e: XMLNode, _ inherited: (TimeInterval, TimeInterval)) -> (TimeInterval, TimeInterval) {
        let s = e.attr("begin").flatMap(parseTime) ?? inherited.0
        let en = e.attr("end").flatMap(parseTime) ?? inherited.1
        return (s, en)
    }

    private static func metadataTexts(_ root: XMLNode, container: String) -> [String: String] {
        var out: [String: String] = [:]
        for c in root.all(container) {
            for t in c.all("text") {
                guard let key = t.attr("for") else { continue }
                let value = t.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if out[key] == nil, !value.isEmpty { out[key] = value }
            }
        }
        return out
    }

    public static func parseTime(_ raw: String) -> TimeInterval? {
        var v = raw.trimmingCharacters(in: .whitespaces)
        if v.hasSuffix("ms"), let ms = Double(v.dropLast(2)) { return ms / 1000 }
        if v.hasSuffix("s") { v.removeLast() }
        let parts = v.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let n = Double(part) else { return nil }
            total = total * 60 + n
        }
        return total
    }
}
