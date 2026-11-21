import Foundation
import NaturalLanguage
import SingCore
import Translation

public struct TranslationLanguage: Codable, Sendable, Hashable {
    public var code: String
    public var name: String
}

/// Lyric translation with Apple's on-device models: nothing leaves the Mac.
public enum LyricsTranslator {
    public enum Failure: Error, LocalizedError {
        case needsDownload(source: String, target: String)
        case unsupported(source: String, target: String)

        public var errorDescription: String? {
            switch self {
            case .needsDownload(let s, let t): "The \(s) to \(t) translation model is not downloaded yet."
            case .unsupported(let s, let t): "Translating \(s) to \(t) is not supported on this Mac."
            }
        }
    }

    public static func sourceLanguage(_ lyrics: Lyrics) -> String {
        if let l = lyrics.language, !l.isEmpty { return String(l.prefix(2)) }
        let r = NLLanguageRecognizer()
        r.processString(lyrics.lines.prefix(40).map(\.text).joined(separator: "\n"))
        return r.dominantLanguage?.rawValue ?? "en"
    }

    public static func languages() async -> [TranslationLanguage] {
        let all = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        return all.compactMap { lang -> TranslationLanguage? in
            guard let code = lang.languageCode?.identifier, seen.insert(code).inserted else { return nil }
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            return TranslationLanguage(code: code, name: name.prefix(1).uppercased() + name.dropFirst())
        }.sorted { $0.name < $1.name }
    }

    public static func status(source: String, target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    }

    /// Fills `translation` on every line. Throws `needsDownload` when the language pair is not installed yet.
    public static func translate(_ lyrics: Lyrics, to target: String) async throws -> Lyrics {
        let source = sourceLanguage(lyrics)
        if source == target { return lyrics }
        switch await status(source: source, target: target) {
        case .installed: break
        case .supported: throw Failure.needsDownload(source: source, target: target)
        default: throw Failure.unsupported(source: source, target: target)
        }
        let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        let requests = lyrics.lines.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
        let responses = try await session.translations(from: requests)
        var byID: [Int: String] = [:]
        for r in responses { if let id = r.clientIdentifier.flatMap(Int.init) { byID[id] = r.targetText } }
        var out = lyrics
        for i in out.lines.indices { out.lines[i].translation = byID[out.lines[i].id] }
        return out
    }
}
