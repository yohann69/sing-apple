import AVFoundation
import Foundation
import NaturalLanguage
import SingCore
import Speech

/// On-device word timing: transcribes the separated vocal stem with Apple's SpeechTranscriber,
/// then aligns the known lyrics to the recognized words.
public enum SpeechAligner {
    public enum AlignError: Error, LocalizedError {
        case unsupportedLanguage(String)
        case noAudio

        public var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let l): "On-device speech recognition does not support \(l)"
            case .noAudio: "No vocal stem to analyse"
            }
        }
    }

    public static func language(for lyrics: Lyrics, hint: String?) -> String {
        if let hint, !hint.isEmpty { return String(hint.prefix(2)) }
        let r = NLLanguageRecognizer()
        r.processString(lyrics.lines.prefix(40).map(\.text).joined(separator: "\n"))
        return r.dominantLanguage?.rawValue ?? "en"
    }

    public static func recognize(vocals url: URL, language: String) async throws -> [TimedWord] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw AlignError.unsupportedLanguage(language)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collector = Task {
            var words: [TimedWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    let parts = text.split(whereSeparator: \.isWhitespace)
                    guard !parts.isEmpty else { continue }
                    let start = range.start.seconds, end = range.end.seconds
                    let step = (end - start) / Double(parts.count)
                    for (i, p) in parts.enumerated() {
                        words.append(TimedWord(text: String(p), start: start + step * Double(i), end: start + step * Double(i + 1)))
                    }
                }
            }
            return words
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.sorted { $0.start < $1.start }
    }

    /// Word-synced lyrics from line-synced or plain ones, or nil when too little was recognized.
    public static func upgrade(_ lyrics: Lyrics, vocals: URL, duration: TimeInterval, languageHint: String?) async throws -> Lyrics? {
        let lang = language(for: lyrics, hint: languageHint)
        let words = try await recognize(vocals: vocals, language: lang)
        let result = LyricsAligner.align(lyrics, recognized: words, duration: duration, language: lang)
        if lyrics.kind == .plain && result.matchedRatio < 0.3 { return nil }
        if result.matchedRatio < 0.15 { return nil }
        var out = result.lyrics
        out.language = out.language ?? lang
        return out
    }
}
