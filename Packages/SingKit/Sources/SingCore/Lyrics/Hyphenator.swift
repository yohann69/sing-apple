import Foundation

/// Splits words into syllables with the system's hyphenation dictionaries (French, English, German, Spanish…).
public enum Hyphenator {
    public static func syllables(_ word: String, language: String?) -> [String] {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 4 else { return [word] }
        let locale = Locale(identifier: language ?? "en") as CFLocale
        guard CFStringIsHyphenationAvailableForLocale(locale) else { return [word] }
        let s = trimmed as CFString
        let length = CFStringGetLength(s)
        var cuts: [Int] = []
        var i = length
        while i > 0 {
            let loc = CFStringGetHyphenationLocationBeforeIndex(s, i, CFRange(location: 0, length: length), 0, locale, nil)
            guard loc != kCFNotFound, loc > 0, loc < i else { break }
            cuts.insert(loc, at: 0)
            i = loc
        }
        guard !cuts.isEmpty else { return [word] }
        let ns = trimmed as NSString
        var out: [String] = []
        var start = 0
        for c in cuts + [length] {
            out.append(ns.substring(with: NSRange(location: start, length: c - start)))
            start = c
        }
        if word.hasSuffix(" "), !out.isEmpty { out[out.count - 1] += " " }
        return out.filter { !$0.isEmpty }
    }

    /// Vowel groups, a rough measure of how long a syllable is sung.
    public static func vowelWeight(_ s: String) -> Int {
        var groups = 0
        var inVowel = false
        for ch in s.lowercased() {
            let v = "aeiouyàâäéèêëîïôöùûüœæáíóú".contains(ch)
            if v && !inVowel { groups += 1 }
            inVowel = v
        }
        return max(1, groups)
    }
}
