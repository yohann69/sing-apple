#if os(macOS)
import Foundation
import FoundationModels
import SingCore

/// Library filters read from a sentence like "a slow French song for two".
@Generable
struct AskFilters {
    @Guide(description: "Words to search in titles and artists, empty when the request only describes a kind of song")
    var text: String
    @Guide(description: "Decade as a year like 1980, or 0 when not asked")
    var decade: Int
    @Guide(description: "ISO 639-1 language code of the lyrics like fr or en, empty when not asked")
    var language: String
    @Guide(description: "Music genre like Pop, Rock, Hip-Hop, empty when not asked")
    var genre: String
    @Guide(description: "True when the request is for two singers or a duet")
    var duet: Bool
}

@Generable
struct Commentary {
    @Guide(description: "A playful title of two to four words for the performance, like Vibrato royalty")
    var title: String
    @Guide(description: "One short, kind and funny sentence about the performance, under 20 words")
    var comment: String
}

extension HostController {
    public func duetSuggestions(_ a: SingerID, _ b: SingerID) async throws -> [Suggestion] {
        try await stats.duetSuggestions(a, b).map { s in Suggestion(song: songs.first { $0.id == s.song.id } ?? s.song, reason: s.reason) }
    }

    var languageModelReady: Bool { SystemLanguageModel.default.availability == .available }

    /// Natural language search: Apple's on-device model turns the sentence into filters; keywords otherwise.
    public func ask(_ sentence: String) async throws -> SearchResponse {
        var f = Self.heuristicFilters(sentence)
        if languageModelReady {
            let session = LanguageModelSession(instructions: "You turn a karaoke song request into search filters for a music library. Only fill what the request asks for.")
            if let r = try? await session.respond(to: sentence, generating: AskFilters.self).content {
                f = (r.text, r.decade > 1900 ? r.decade : nil, r.language.isEmpty ? nil : r.language.lowercased(), r.genre.isEmpty ? nil : r.genre, r.duet)
            }
        }
        let filters = SearchFilters(duetOnly: f.duet, decade: f.decade, genre: nil, language: f.language)
        var found = try await library.search(f.text, filters: filters, limit: 80).map { summary($0) }.filter { !familyHidden($0) }
        if let g = f.genre?.lowercased() {
            let matching = found.filter { $0.genre?.lowercased().contains(g) == true }
            if !matching.isEmpty { found = matching }
        }
        if found.isEmpty, !f.text.isEmpty {
            found = try await library.search("", filters: filters, limit: 40).map { summary($0) }
        }
        return SearchResponse(songs: Array(found.prefix(40)), total: found.count)
    }

    static func heuristicFilters(_ s: String) -> (text: String, decade: Int?, language: String?, genre: String?, duet: Bool) {
        let l = s.lowercased()
        var decade: Int?
        if let m = l.range(of: #"\b(19|20)?([0-9])0s\b"#, options: .regularExpression) {
            let digits = l[m].filter(\.isNumber)
            if digits.count == 4, let y = Int(digits) { decade = y } else if digits.count == 2, let d = Int(digits) { decade = d >= 30 ? 1900 + d : 2000 + d }
        }
        let languages = ["french": "fr", "français": "fr", "english": "en", "anglais": "en", "spanish": "es", "espagnol": "es", "italian": "it", "german": "de", "japanese": "ja", "korean": "ko", "portuguese": "pt"]
        let lang = languages.first { l.contains($0.key) }?.value
        let duet = ["duet", "duo", "for two", "à deux", "two of us"].contains { l.contains($0) }
        let genres = ["rock", "pop", "rap", "hip-hop", "disco", "country", "metal", "jazz", "r&b", "soul", "reggae", "electro"]
        let genre = genres.first { l.contains($0) }
        let stop = Set(["a", "an", "the", "song", "songs", "something", "some", "for", "two", "us", "me", "with", "slow", "fast", "upbeat", "sad", "happy", "une", "un", "chanson", "pour"] + languages.keys + genres + ["duet", "duo"])
        let words = l.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !stop.contains($0) && !($0.hasSuffix("0s") && $0.count <= 5) }
        return (words.joined(separator: " "), decade, lang, genre, duet)
    }

    /// Replaces the template title and comment with a line from the on-device model when it answers quickly.
    func commentWithAI(entryID: String) {
        guard languageModelReady, let r = lastResult, let total = r.total else { return }
        let cats = r.categories.map { "\($0.name) \($0.value)" }.joined(separator: ", ")
        let prompt = "Karaoke performance of \(r.songTitle) by \(r.artist), sung by \(r.singers.map(\.name).joined(separator: " and ")). Score \(total)/100. \(cats)."
        Task {
            let session = LanguageModelSession(instructions: "You are a warm, witty karaoke host. Never mock the singer.")
            guard let c = try? await session.respond(to: prompt, generating: Commentary.self).content, lastResult?.entryID == entryID else { return }
            lastResult?.title = c.title
            lastResult?.comment = c.comment
            scheduleBroadcast()
        }
    }
}
#endif
