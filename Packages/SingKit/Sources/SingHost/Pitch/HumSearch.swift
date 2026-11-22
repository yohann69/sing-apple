import Foundation
import SingCore

/// Finds songs from a hummed melody: key does not matter, only the ups and downs between notes.
public enum HumSearch {
    /// Pitch contour of a hum as note-to-note intervals in semitones.
    static func intervals(_ notes: [PitchNote]) -> [Float] {
        let solid = notes.filter { $0.end - $0.start >= 0.08 }
        var merged: [Float] = []
        for n in solid {
            if let last = merged.last, abs(last - n.midi) < 0.6 { continue }
            merged.append(n.midi)
        }
        return zip(merged.dropFirst(), merged).map { max(-12, min(12, $0 - $1)) }
    }

    /// Lowest cost of matching the hum anywhere inside the song (subsequence DTW), per hummed interval.
    static func cost(hum: [Float], song: [Float]) -> Float {
        guard hum.count >= 3, song.count >= hum.count else { return .infinity }
        let n = hum.count, m = song.count
        var prev = [Float](repeating: 0, count: m + 1)
        var cur = [Float](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = .infinity
            for j in 1...m {
                let d = min(4, abs(hum[i - 1] - song[j - 1]))
                cur[j] = d + min(prev[j - 1], min(prev[j] + 0.5, cur[j - 1] + 0.5))
            }
            swap(&prev, &cur)
        }
        return (prev.dropFirst().min() ?? .infinity) / Float(n)
    }

    public static func rank(hum: PitchTrack, songs: [(SongID, PitchTrack)], limit: Int = 5) -> [(SongID, Float)] {
        let h = intervals(hum.notes)
        guard h.count >= 3 else { return [] }
        return songs.map { ($0.0, cost(hum: h, song: intervals($0.1.notes))) }
            .filter { $0.1.isFinite }
            .sorted { $0.1 < $1.1 }
            .prefix(limit).map { $0 }
    }
}
