#if os(macOS)
import Foundation
import SingCore

extension HostController {
    /// Live mic levels for pads and other screens, eight times a second while a song plays.
    func startMeters() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(125))
                guard let self, self.nowPlaying.state == .playing || self.nowPlaying.state == .paused else { return }
                guard self.mic.isRunning else { continue }
                await self.server?.broadcast(.meter(.init(levels: self.micLevels)))
            }
        }
    }

    public var micChannels: Int { mic.channelCount }

    /// Video looped behind the lyrics when the TV background is set to video.
    public var tvVideoURL: URL? {
        get { UserDefaults.standard.url(forKey: "tvVideoURL") }
        set { UserDefaults.standard.set(newValue, forKey: "tvVideoURL") }
    }

    /// Starts the wireless-mic receiver if needed and hands this device a key.
    public func startPhoneMic(pad: PadIdentity) throws -> PhoneMicSession {
        guard mic.isRunning else { throw ErrorBody(code: "mic", message: "Turn the Mac's microphone on first.") }
        let p = UInt16(port + 2)
        try mic.phones.start(port: p)
        let key = mic.phones.issueKey(for: pad.padID)
        audit(pad.name, "started using this device as a mic")
        return PhoneMicSession(port: Int(p), key: key.base64EncodedString())
    }

    public func stopPhoneMic(pad: PadIdentity) { mic.phones.revoke(pad.padID) }

    var phonePitch: Float? { mic.phones.activeDevices.isEmpty ? nil : mic.phones.pitch.midi }

    public var micLevels: [Float] { mic.isRunning ? mic.channelLevels + (mic.phones.activeDevices.isEmpty ? [] : [mic.phones.meter.value]) : [] }

    /// With one mic per singer, each singer is scored on their own input channel.
    func micScores(_ entry: QueueEntry) -> [RankedName]? {
        guard mic.channelCount > 1, entry.singers.count >= 2 else { return nil }
        var out: [RankedName] = []
        for (i, s) in entry.singers.prefix(4).enumerated() {
            let ch = settings.playback.micSlots.indices.contains(i) ? settings.playback.micSlots[i] : i
            guard ch < mic.channelCount, let r = channelKeepers[ch].result(track: pitchTrack, upTo: playback.duration, tolerance: scoreTolerance) else { continue }
            out.append(RankedName(name: s.name, count: r.total, colorHex: s.colorHex))
        }
        return out.count >= 2 ? out : nil
    }

    /// Nudges the voice toward the guide note; strength 1 snaps fully, small values only tidy up.
    func correctPitch(target: Float?) {
        guard settings.playback.pitchCorrection > 0 else { return }
        guard let t = target, let sung = mic.livePitch.midi else { mic.correctionCents = 0; return }
        let folded = PitchTrack.foldOctave(sung, toward: t)
        let off = t - folded
        mic.correctionCents = abs(off) < 1.5 ? Float(off) * 100 * Float(settings.playback.pitchCorrection) : 0
    }
}
#endif
