#if os(macOS)
import Foundation
import SingCore

/// The results jingle: it plays as the score comes up, then soft music carries on under the results
/// and the party recap until the next song starts. A shorter version greets the room when Sing! opens.
extension HostController {
    static var jingleURL: URL? { Bundle.main.url(forResource: "jingle", withExtension: "caf") }
    static var bedURL: URL? { Bundle.main.url(forResource: "results-bed", withExtension: "caf") }

    var cueVolume: Double { settings.playback.resultsMusicVolume * settings.playback.musicVolume }

    func updateCue(from old: PlaybackState) {
        let state = nowPlaying.state
        switch state {
        case .finished:
            guard old == .playing || old == .paused, settings.playback.resultsMusic, let j = Self.jingleURL else { return }
            playback.playCue(jingle: j, bed: Self.bedURL, volume: cueVolume)
        case .idle:
            if recap != nil, settings.playback.resultsMusic, let j = Self.jingleURL {
                if !playback.cuePlaying { playback.playCue(jingle: j, bed: Self.bedURL, volume: cueVolume) }
            } else if old == .finished || recap == nil {
                playback.stopCue(fade: 2.5)
            }
        case .preparing, .countdown, .playing, .paused:
            playback.stopCue(fade: 1.2)
        }
    }

    /// The jingle alone, as the app opens.
    func playOpeningJingle() {
        guard settings.playback.resultsMusic, let j = Self.jingleURL, nowPlaying.state == .idle else { return }
        playback.playCue(jingle: j, bed: nil, volume: cueVolume)
    }
}
#endif
