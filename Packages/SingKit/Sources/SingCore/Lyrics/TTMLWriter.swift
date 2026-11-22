import Foundation

/// Apple-style TTML with singer agents, word or syllable timing, background vocals, translations and provenance.
public enum TTMLWriter {
    public static func write(_ l: Lyrics, title: String? = nil, artist: String? = nil) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func t(_ x: TimeInterval) -> String {
            let v = max(0, x)
            let m = Int(v) / 60
            return String(format: "%d:%06.3f", m, v - Double(m * 60))
        }
        let timing = l.kind >= .word ? "Word" : (l.kind == .line ? "Line" : "None")
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        x += "<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\" xmlns:sing=\"https://github.com/yohann69/sing-apple\""
        if let lang = l.language { x += " xml:lang=\"\(esc(lang))\"" }
        x += " itunes:timing=\"\(timing)\">\n<head>\n<metadata>\n"
        if let title { x += "<ttm:title>\(esc(title))</ttm:title>\n" }
        if let artist { x += "<ttm:desc>\(esc(artist))</ttm:desc>\n" }
        let agents = l.agents.isEmpty ? [Agent(id: "v1")] : l.agents
        for a in agents {
            x += "<ttm:agent type=\"\(a.isGroup ? "group" : "person")\" xml:id=\"\(esc(a.id))\">"
            if let n = a.name { x += "<ttm:name type=\"full\">\(esc(n))</ttm:name>" }
            x += "</ttm:agent>\n"
        }
        x += "<sing:provenance source=\"\(l.source.rawValue)\" model=\"\(esc(l.model ?? ""))\" needsReview=\"\(l.needsReview == true)\"/>\n"
        let translated = l.lines.filter { $0.translation != nil }
        if !translated.isEmpty {
            x += "<iTunesMetadata xmlns=\"http://music.apple.com/lyric-ttml-internal\"><translations><translation type=\"subtitle\">"
            for line in translated { x += "<text for=\"L\(line.id + 1)\">\(esc(line.translation!))</text>" }
            x += "</translation></translations></iTunesMetadata>\n"
        }
        x += "</metadata>\n</head>\n"
        let end = l.lines.last?.end ?? 0
        x += "<body dur=\"\(t(end))\">\n<div begin=\"\(t(l.lines.first?.start ?? 0))\" end=\"\(t(end))\">\n"
        func spans(_ segs: [LyricSegment]) -> String {
            var out = ""
            for s in segs {
                let text = s.text.trimmingCharacters(in: .whitespaces)
                out += "<span begin=\"\(t(s.start))\" end=\"\(t(s.end))\">\(esc(text))</span>"
                if s.endsWord { out += " " }
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
        for line in l.lines {
            x += "<p begin=\"\(t(line.start))\" end=\"\(t(line.end))\" itunes:key=\"L\(line.id + 1)\" ttm:agent=\"\(esc(line.agent ?? agents[0].id))\""
            if let c = line.confidence { x += " sing:confidence=\"\(String(format: "%.2f", c))\"" }
            x += ">"
            if l.kind >= .word {
                x += spans(line.segments)
                if !line.background.isEmpty { x += "<span ttm:role=\"x-bg\">\(spans(line.background))</span>" }
            } else {
                x += esc(line.text)
            }
            x += "</p>\n"
        }
        x += "</div>\n</body>\n</tt>\n"
        return Data(x.utf8)
    }
}
