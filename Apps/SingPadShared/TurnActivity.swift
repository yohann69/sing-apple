import ActivityKit
import Foundation

/// "You're up in 2 songs" on the lock screen and in the Dynamic Island.
struct TurnAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var songsAway: Int
        var songTitle: String
        var artist: String
        var nowPlaying: String?
    }
    var singerName: String
    var colorHex: String
}
