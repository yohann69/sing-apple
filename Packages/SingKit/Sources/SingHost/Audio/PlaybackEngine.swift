#if os(macOS)
import AVFoundation
import Foundation
import SingCore
import SingObjC

func objc(_ body: () -> Void) throws {
    var error: NSError?
    if !SingTryObjC(body, &error) { throw error ?? NSError(domain: "SingObjC", code: 1) }
}

/// Plays the instrumental and vocal stems in lockstep, with the guide vocal as the vocal stem's volume.
@MainActor
public final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private let instrumental = AVAudioPlayerNode()
    private let vocals = AVAudioPlayerNode()
    private let stemMixer = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var instrumentalFile: AVAudioFile?
    private var vocalsFile: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var generation = 0
    private var outputUID: String?

    public private(set) var isPlaying = false
    public private(set) var duration: TimeInterval = 0
    public var onFinished: (() -> Void)?

    /// A second output (singer's headphones) that plays the same song in step.
    public var mirror: PlaybackEngine?
    /// Guide vocal level in the mirror, so the singer can hear the melody without the room hearing it.
    public var mirrorGuide: Double = 0.5

    public var guideVocal: Double = 0 { didSet { vocals.volume = Float(guideVocal) } }
    public var volume: Double = 0.9 { didSet { applyVolume() } }
    /// Per-song gain from loudness analysis, so every song plays at the same level.
    public var normalization: Double = 1 { didSet { applyVolume() } }
    /// Semitones; the voice guide and music move together.
    public var keyShift: Int = 0 { didSet { timePitch.pitch = Float(keyShift * 100); mirror?.keyShift = keyShift } }
    public var tempo: Double = 1 { didSet { timePitch.rate = Float(max(0.5, min(1.5, tempo))); mirror?.tempo = tempo } }

    /// Fade-in and fade-out envelope at the song's edges.
    public var fade: Double = 1 { didSet { if abs(fade - oldValue) > 0.005 { applyVolume() } } }
    private func applyVolume() { stemMixer.outputVolume = Float(volume * normalization * fade) }

    private var recorder: TapRecorder?
    let cueJingle = AVAudioPlayerNode()
    let cueBed = AVAudioPlayerNode()
    let cueMixer = AVAudioMixerNode()
    var cueGeneration = 0
    var engineForCue: AVAudioEngine { engine }

    /// Records the music as heard (after key and tempo) until `stopRecording`.
    func startRecording(to url: URL) {
        stopRecording()
        let rec = TapRecorder(url: url)
        recorder = rec
        let node = timePitch
        try? objc {
            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 4096, format: nil, block: recordingTap(rec))
        }
    }

    func stopRecording() {
        guard let rec = recorder else { return }
        let node = timePitch
        try? objc { node.removeTap(onBus: 0) }
        rec.close()
        recorder = nil
    }

    /// Called when the output device changes or disappears (HDMI unplugged).
    public var onConfigurationChange: (() -> Void)?
    nonisolated(unsafe) private var configObserver: NSObjectProtocol?

    public init() {
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onConfigurationChange?() }
        }
        engine.attach(instrumental)
        engine.attach(vocals)
        engine.attach(stemMixer)
        engine.attach(timePitch)
        engine.connect(stemMixer, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    }

    public func setOutputDevice(uid: String?) {
        guard uid != outputUID else { return }
        outputUID = uid
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        if let dev = AudioDevices.device(uid: uid), let unit = engine.outputNode.audioUnit {
            AudioDevices.assign(dev.id, to: unit)
        }
        if wasRunning { try? engine.start() }
    }

    /// Output latency in seconds, used to delay lyrics so they match what people hear.
    public var outputLatency: TimeInterval {
        engine.outputNode.presentationLatency
    }

    public func load(instrumental instURL: URL, vocals vocURL: URL?) throws {
        stop()
        if let m = mirror { try? m.load(instrumental: instURL, vocals: vocURL); m.guideVocal = mirrorGuide }
        let inst = try AVAudioFile(forReading: instURL)
        let voc = try vocURL.map { try AVAudioFile(forReading: $0) }
        instrumentalFile = inst
        vocalsFile = voc
        sampleRate = inst.processingFormat.sampleRate
        duration = Double(inst.length) / sampleRate
        let engine = self.engine, instrumental = self.instrumental, vocals = self.vocals, stemMixer = self.stemMixer
        try objc {
            engine.disconnectNodeOutput(instrumental)
            engine.disconnectNodeOutput(vocals)
            engine.connect(instrumental, to: stemMixer, format: inst.processingFormat)
            engine.connect(vocals, to: stemMixer, format: voc?.processingFormat ?? inst.processingFormat)
        }
        vocals.volume = Float(guideVocal)
        applyVolume()
        startFrame = 0
        engine.prepare()
    }

    /// After a device change the engine stops; restart it on whatever output is there now and carry on.
    public func recoverOutput() {
        let wasPlaying = isPlaying
        let at = position
        isPlaying = false
        generation += 1
        if let dev = AudioDevices.device(uid: outputUID), let unit = engine.outputNode.audioUnit {
            AudioDevices.assign(dev.id, to: unit)
        } else {
            outputUID = nil
        }
        engine.prepare()
        try? engine.start()
        if wasPlaying { try? play(from: at) } else { startFrame = AVAudioFramePosition(at * sampleRate) }
    }

    public var position: TimeInterval {
        guard let nodeTime = instrumental.lastRenderTime, isPlaying,
              let playerTime = instrumental.playerTime(forNodeTime: nodeTime) else {
            return Double(startFrame) / sampleRate
        }
        return Double(startFrame + playerTime.sampleTime) / sampleRate
    }

    public func play(from time: TimeInterval? = nil) throws {
        guard let inst = instrumentalFile else { return }
        if let time { startFrame = AVAudioFramePosition(max(0, min(time, duration)) * sampleRate) }
        if !engine.isRunning { try engine.start() }
        try? mirror?.play(from: Double(startFrame) / sampleRate)
        instrumental.stop()
        vocals.stop()
        generation += 1
        let gen = generation
        let remaining = AVAudioFrameCount(max(0, inst.length - startFrame))
        guard remaining > 0 else { onFinished?(); return }
        let length = inst.length
        instrumental.scheduleSegment(inst, startingFrame: startFrame, frameCount: remaining, at: nil, completionCallbackType: .dataPlayedBack, completionHandler: Self.completion { [weak self] in
            guard let self, self.generation == gen, self.isPlaying else { return }
            self.isPlaying = false
            self.startFrame = length
            self.onFinished?()
        })
        if let voc = vocalsFile {
            let vRemaining = AVAudioFrameCount(max(0, voc.length - startFrame))
            if vRemaining > 0 { vocals.scheduleSegment(voc, startingFrame: startFrame, frameCount: vRemaining, at: nil) }
        }
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        let instrumental = self.instrumental, vocals = self.vocals, hasVocals = vocalsFile != nil
        try objc {
            instrumental.play(at: start)
            if hasVocals { vocals.play(at: start) }
        }
        isPlaying = true
    }

    nonisolated static func completion(_ body: @escaping @MainActor @Sendable () -> Void) -> AVAudioPlayerNodeCompletionHandler {
        { @Sendable _ in Task { @MainActor in body() } }
    }

    public func pause() {
        guard isPlaying else { return }
        mirror?.pause()
        startFrame = AVAudioFramePosition(position * sampleRate)
        isPlaying = false
        generation += 1
        instrumental.stop()
        vocals.stop()
    }

    public func seek(to time: TimeInterval) throws {
        if isPlaying {
            try play(from: time)
        } else {
            try? mirror?.seek(to: time)
            startFrame = AVAudioFramePosition(max(0, min(time, duration)) * sampleRate)
        }
    }

    public func stop() {
        mirror?.stop()
        isPlaying = false
        generation += 1
        instrumental.stop()
        vocals.stop()
        startFrame = 0
    }
}

/// The results jingle and the soft music that follows it, on the same output as the songs.
extension PlaybackEngine {
    /// Plays the jingle, then loops the bed until `stopCue`. With `bed` nil only the jingle plays.
    public func playCue(jingle: URL, bed: URL?, volume: Double) {
        stopCue(fade: 0)
        guard let j = try? AVAudioFile(forReading: jingle) else { return }
        let b = bed.flatMap { try? AVAudioFile(forReading: $0) }
        let bedBuffer = b.flatMap { f -> AVAudioPCMBuffer? in
            guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
            try? f.read(into: buf)
            return buf
        }
        let engine = self.engineForCue, jn = cueJingle, bn = cueBed, mixer = cueMixer
        do {
            try objc {
                if jn.engine == nil { engine.attach(jn); engine.attach(bn); engine.attach(mixer) }
                engine.disconnectNodeOutput(jn)
                engine.disconnectNodeOutput(bn)
                engine.connect(jn, to: mixer, format: j.processingFormat)
                engine.connect(bn, to: mixer, format: bedBuffer?.format ?? j.processingFormat)
                engine.connect(mixer, to: engine.mainMixerNode, format: nil)
            }
            if !engine.isRunning { try engine.start() }
        } catch { return }
        mixer.outputVolume = Float(volume)
        cueGeneration += 1
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        jn.scheduleFile(j, at: nil)
        if let bedBuffer {
            // The bed comes in just under the jingle's last chord, so the music never stops.
            let offset = max(0, Double(j.length) / j.processingFormat.sampleRate - 0.9)
            let bedStart = AVAudioTime(hostTime: start.hostTime + AVAudioTime.hostTime(forSeconds: offset))
            bn.volume = 0.85
            bn.scheduleBuffer(bedBuffer, at: nil, options: .loops)
            try? objc { bn.play(at: bedStart) }
        }
        try? objc { jn.play(at: start) }
    }

    /// Fades the cue out over `fade` seconds.
    public func stopCue(fade: TimeInterval = 1.5) {
        cueGeneration += 1
        let gen = cueGeneration
        let jn = cueJingle, bn = cueBed, mixer = cueMixer
        guard jn.engine != nil, jn.isPlaying || bn.isPlaying else { return }
        guard fade > 0 else { jn.stop(); bn.stop(); return }
        let from = mixer.outputVolume
        Task { @MainActor [weak self] in
            let steps = 20
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(fade / Double(steps)))
                guard let self, self.cueGeneration == gen else { return }
                mixer.outputVolume = from * Float(steps - i) / Float(steps)
            }
            jn.stop()
            bn.stop()
        }
    }

    public var cuePlaying: Bool { cueJingle.isPlaying || cueBed.isPlaying }
}

/// Built outside the main actor so the audio thread can call it.
nonisolated func recordingTap(_ rec: TapRecorder) -> AVAudioNodeTapBlock {
    { @Sendable buf, _ in rec.write(buf) }
}

/// Integrated loudness, approximated as gated RMS of the full mix in dBFS.
enum Loudness {
    static let target = -18.0

    static func measure(_ urls: [URL]) -> Double? {
        var sum = 0.0, count = 0
        for url in urls {
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            let chunk: AVAudioFrameCount = 1 << 15
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { continue }
            var blocks: [Double] = []
            while (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 {
                var s = 0.0
                for c in 0..<Int(buf.format.channelCount) {
                    guard let ch = buf.floatChannelData?[c] else { continue }
                    for i in stride(from: 0, to: Int(buf.frameLength), by: 4) { s += Double(ch[i] * ch[i]) }
                }
                blocks.append(s / Double(max(1, Int(buf.frameLength) / 4 * Int(buf.format.channelCount))))
            }
            let gate = (blocks.max() ?? 0) * 0.001
            for b in blocks where b > gate { sum += b; count += 1 }
        }
        guard count > 0, sum > 0 else { return nil }
        return 10 * log10(sum / Double(count))
    }

    static func gain(forDB db: Double) -> Double {
        max(0.5, min(2.0, pow(10, (target - db) / 20)))
    }
}

/// Live microphone with effects, routed to the chosen output on its own low-latency engine.
@MainActor
public final class MicEngine {
    private var engine = AVAudioEngine()
    /// False when only phones are used as mics: the Mac's own input is never opened.
    public private(set) var usesMacMic = true
    private var inputTouched = false
    private let reverb = AVAudioUnitReverb()
    private let delay = AVAudioUnitDelay()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private let eq = AVAudioUnitEQ(numberOfBands: 3)
    private let tuner = AVAudioUnitTimePitch()
    /// 0 disables the tuner so it adds no latency.
    public var correctionStrength: Double = 0 {
        didSet {
            tuner.bypass = correctionStrength <= 0
            if correctionStrength <= 0 { tuner.pitch = 0 }
            if (correctionStrength > 0) != (oldValue > 0), isRunning { stop(); try? start(macMic: usesMacMic) }
        }
    }
    public var correctionCents: Float = 0 { didSet { tuner.pitch = max(-150, min(150, correctionCents)) } }
    private let inputMixer = AVAudioMixerNode()
    private var aggregate: AudioDeviceID?
    private var configured = false
    public private(set) var isRunning = false
    public var level: Float { meter.value }
    private var recorder: TapRecorder?

    /// The voice with its effects, as the room hears it.
    func startRecording(to url: URL) {
        stopRecording()
        guard isRunning else { return }
        let rec = TapRecorder(url: url)
        recorder = rec
        let node = limiter
        try? objc {
            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 4096, format: nil, block: recordingTap(rec))
        }
    }

    func stopRecording() {
        guard let rec = recorder else { return }
        let node = limiter
        try? objc { node.removeTap(onBus: 0) }
        rec.close()
        recorder = nil
    }

    var inputLatency: TimeInterval { usesMacMic && inputTouched ? engine.inputNode.presentationLatency : 0 }
    /// Loudest sample since the mic started; exactly zero means macOS is feeding silence (access blocked).
    public var peakSinceStart: Float { meter.peak }
    public private(set) var deviceName: String?
    private let meter = LevelMeter()
    public let livePitch = LivePitch()
    /// One pitch tracker and meter per input channel (up to four mics on one interface).
    public let channelPitch = (0..<4).map { _ in LivePitch() }
    let channelMeters = (0..<4).map { _ in LevelMeter() }
    public private(set) var channelCount = 1
    /// When the engine last (re)started, so a silent first moment is not mistaken for blocked access.
    public private(set) var startedAt: Date?
    public var channelLevels: [Float] { channelMeters.prefix(channelCount).map(\.value) }
    /// Per-mic volume, used when the mics are mixed separately.
    public let mixGains = MixGains()
    /// Mix each channel with its own volume (adds about 40 ms of latency).
    public var separateMics = false { didSet { if separateMics != oldValue, isRunning { stop(); try? start(macMic: usesMacMic) } } }
    private var splitSource: AVAudioSourceNode?
    /// Wireless mics from phones, mixed in with the wired ones.
    let phones = PhoneMicReceiver()
    private var phoneSource: AVAudioSourceNode?
    private let ring = MonoRing()
    private var inputUID: String?
    private var outputUID: String?

    public var gain: Double = 0.8 { didSet { applyGain() } }
    /// Temporary cut while a howl is detected.
    public var duck: Double = 1 { didSet { applyGain() } }
    public var reverbMix: Double = 0.35 { didSet { reverb.wetDryMix = Float(reverbMix * 100) } }
    public var echo: Double = 0 { didSet { applyPreset() } }
    public var preset: MicPreset = .hall { didSet { if preset != oldValue { applyPreset() } } }

    private func applyGain() { engine.mainMixerNode.outputVolume = Float(gain * duck) }

    /// Each preset is a reverb room, an echo and a tone curve; the reverb amount slider scales the room.
    func applyPreset() {
        let room: AVAudioUnitReverbPreset
        var delayTime = 0.0, delayMix = 0.0, feedback = 0.0
        var presence: Float = 2.5, air: Float = 0
        switch preset {
        case .natural: room = .smallRoom; presence = 1
        case .studio: room = .mediumRoom; presence = 3; air = 2
        case .hall: room = .largeHall
        case .stadium: room = .cathedral; delayTime = 0.28; delayMix = 18; feedback = 25
        case .echo: room = .mediumHall; delayTime = 0.36; delayMix = 30; feedback = 40
        case .radio: room = .smallRoom; presence = 6; air = -10
        }
        reverb.loadFactoryPreset(room)
        reverb.wetDryMix = Float(reverbMix * 100)
        let extra = echo * 35
        delay.delayTime = delayTime > 0 ? delayTime : 0.32
        delay.wetDryMix = Float(min(70, delayMix + extra))
        delay.feedback = Float(feedback > 0 ? feedback : 30)
        delay.bypass = delay.wetDryMix <= 0
        eq.bands[0].frequency = preset == .radio ? 300 : 90
        eq.bands[1].gain = presence
        eq.bands[2].gain = air
        eq.bands[2].bypass = air == 0
    }

    public init() {
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 35
        let low = eq.bands[0]
        low.filterType = .highPass
        low.frequency = 90
        low.bypass = false
        let presence = eq.bands[1]
        presence.filterType = .parametric
        presence.frequency = 3500
        presence.bandwidth = 1
        presence.gain = 2.5
        presence.bypass = false
        let air = eq.bands[2]
        air.filterType = .highShelf
        air.frequency = 9000
        air.bypass = true
        applyPreset()
    }

    public func configure(inputUID: String?, outputUID: String?) {
        self.inputUID = inputUID
        self.outputUID = outputUID
        if isRunning { stop(); try? start(macMic: usesMacMic) }
    }

    /// Starts the mic chain. With `macMic` false only the phones feed it, and the Mac's input stays closed.
    public func start(macMic: Bool = true) throws {
        guard !isRunning else { return }
        if !macMic, inputTouched { rebuildEngine() }
        usesMacMic = macMic
        if !macMic { return try startPhonesOnly() }
        inputTouched = true
        // On macOS one engine drives one device: a chosen mic and output are joined in a private aggregate.
        let inDev = AudioDevices.device(uid: inputUID)
        let outDev = AudioDevices.device(uid: outputUID)
        let defaultIn = AudioDevices.defaultDevice(input: true).flatMap { id in AudioDevices.all().first { $0.id == id } }
        deviceName = (inDev ?? defaultIn)?.name
        if inDev != nil || outDev != nil {
            let i = inDev ?? defaultIn
            let o = outDev ?? AudioDevices.defaultDevice(input: false).flatMap { id in AudioDevices.all().first { $0.id == id } }
            if let i, let o, let unit = engine.outputNode.audioUnit {
                if i.id == o.id {
                    AudioDevices.assign(o.id, to: unit)
                } else if let agg = AudioDevices.makeAggregate(inputUID: i.uid, outputUID: o.uid) {
                    aggregate = agg
                    AudioDevices.assign(agg, to: unit)
                }
            }
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw SeparationError.badAudio("no microphone") }
        let input = engine.inputNode
        let mixer = engine.mainMixerNode
        channelCount = max(1, min(4, Int(format.channelCount)))
        // A pitch shifter cannot sit downstream of the live input, so pitch correction takes the same
        // tap-and-replay path as separate mic volumes (about 40 ms more latency).
        let split = (separateMics && format.channelCount > 1) || correctionStrength > 0
        let tapBlock = Self.tap(meter, pitch: livePitch, channels: Array(zip(channelMeters, channelPitch)), sampleRate: format.sampleRate, ring: split ? ring : nil, gains: mixGains)
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        if split, splitSource == nil {
            splitSource = AVAudioSourceNode(format: mono, renderBlock: Self.render(ring))
        }
        let source = split ? splitSource : nil
        let phoneFormat = AVAudioFormat(standardFormatWithSampleRate: PhoneMicReceiver.sampleRate, channels: 1)!
        if phoneSource == nil { phoneSource = AVAudioSourceNode(format: phoneFormat, renderBlock: Self.render(phones.ring)) }
        let phoneNode = phoneSource
        if let p = phoneNode, p.engine == nil { engine.attach(p) }
        let useTuner = split
        let eq = self.eq, reverb = self.reverb, engine = self.engine, inMixer = self.inputMixer, attach = !configured
        let delay = self.delay, limiter = self.limiter, tuner = self.tuner
        tuner.bypass = correctionStrength <= 0
        let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
        try objc {
            if attach {
                engine.attach(inMixer)
                engine.attach(eq)
                engine.attach(tuner)
                engine.attach(delay)
                engine.attach(reverb)
                engine.attach(limiter)
            }
            if let source {
                if source.engine == nil { engine.attach(source) }
                engine.disconnectNodeOutput(input)
                engine.connect(source, to: inMixer, format: mono)
            } else {
                if let s = self.splitSource, s.engine != nil { engine.disconnectNodeOutput(s) }
                engine.connect(input, to: inMixer, format: format)
            }
            if let ps = phoneNode {
                engine.disconnectNodeOutput(ps)
                engine.connect(ps, to: inMixer, format: phoneFormat)
            }
            if useTuner {
                engine.connect(inMixer, to: tuner, format: stereo)
                engine.connect(tuner, to: eq, format: stereo)
            } else {
                engine.disconnectNodeOutput(tuner)
                engine.connect(inMixer, to: eq, format: stereo)
            }
            engine.connect(eq, to: delay, format: stereo)
            engine.connect(delay, to: reverb, format: stereo)
            engine.connect(reverb, to: limiter, format: stereo)
            engine.connect(limiter, to: mixer, format: stereo)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapBlock)
        }
        configured = true
        applyGain()
        try objc { engine.prepare() }
        do {
            try engine.start()
        } catch {
            if let aggregate { AudioDevices.destroyAggregate(aggregate) }
            aggregate = nil
            throw error
        }
        isRunning = true
        startedAt = .now
    }

    /// A fresh engine that has never opened the Mac's input (an engine keeps its input once touched).
    private func rebuildEngine() {
        let nodes: [AVAudioNode?] = [inputMixer, eq, tuner, delay, reverb, limiter, splitSource, phoneSource]
        for n in nodes.compactMap({ $0 }) where n.engine === engine { engine.detach(n) }
        engine = AVAudioEngine()
        configured = false
        inputTouched = false
    }

    private func startPhonesOnly() throws {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let stereo = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48000, channels: 2)!
        let phoneFormat = AVAudioFormat(standardFormatWithSampleRate: PhoneMicReceiver.sampleRate, channels: 1)!
        if phoneSource == nil { phoneSource = AVAudioSourceNode(format: phoneFormat, renderBlock: Self.render(phones.ring)) }
        guard let ps = phoneSource else { return }
        channelCount = 0
        deviceName = nil
        let engine = self.engine, inMixer = self.inputMixer, eq = self.eq, delay = self.delay, reverb = self.reverb
        let limiter = self.limiter, tuner = self.tuner, attach = !configured
        try objc {
            if attach {
                for n in [inMixer, eq, tuner, delay, reverb, limiter] as [AVAudioNode] { engine.attach(n) }
            }
            if ps.engine == nil { engine.attach(ps) }
            engine.disconnectNodeOutput(ps)
            engine.connect(ps, to: inMixer, format: phoneFormat)
            engine.disconnectNodeOutput(tuner)
            engine.connect(inMixer, to: eq, format: stereo)
            engine.connect(eq, to: delay, format: stereo)
            engine.connect(delay, to: reverb, format: stereo)
            engine.connect(reverb, to: limiter, format: stereo)
            engine.connect(limiter, to: engine.mainMixerNode, format: stereo)
        }
        configured = true
        applyGain()
        try objc { engine.prepare() }
        try engine.start()
        isRunning = true
        startedAt = .now
    }

    public func stop() {
        guard isRunning else { return }
        if usesMacMic { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        isRunning = false
        meter.value = 0
        meter.reset()
        if let aggregate { AudioDevices.destroyAggregate(aggregate) }
        aggregate = nil
    }

    nonisolated static func tap(_ meter: LevelMeter, pitch: LivePitch, channels: [(LevelMeter, LivePitch)], sampleRate: Double, ring: MonoRing?, gains: MixGains) -> AVAudioNodeTapBlock {
        { @Sendable buf, _ in
            guard let data = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            let count = min(channels.count, Int(buf.format.channelCount))
            var loudest: Float = 0
            var loudestChannel = 0
            for c in 0..<count {
                let ch = data[c]
                var peak: Float = 0
                for i in 0..<n { peak = max(peak, abs(ch[i])) }
                channels[c].0.value = peak
                if count > 1 { channels[c].1.process(ch, count: n, sampleRate: sampleRate) }
                if peak > loudest { loudest = peak; loudestChannel = c }
            }
            meter.value = loudest
            pitch.process(data[loudestChannel], count: n, sampleRate: sampleRate)
            if let ring {
                let g = gains.values
                var mixed = [Float](repeating: 0, count: n)
                for c in 0..<count {
                    let ch = data[c], k = c < g.count ? g[c] : 1
                    for i in 0..<n { mixed[i] += ch[i] * k }
                }
                ring.write(mixed)
            }
        }
    }

    nonisolated static func render(_ ring: MonoRing) -> AVAudioSourceNodeRenderBlock {
        { _, _, frames, list -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(list)
            guard let out = abl.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.read(into: out, count: Int(frames))
            return noErr
        }
    }
}

public final class MixGains: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Float] = [1, 1, 1, 1]
    public var values: [Float] {
        get { lock.withLock { _values } }
        set { lock.withLock { _values = newValue } }
    }
}

/// Hands the mixed mics from the input tap to the playback graph, with a small cushion.
final class MonoRing: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = [Float](repeating: 0, count: 1 << 15)
    private var readPos = 0
    private var available = 0
    private let cushion = 1536

    func write(_ s: [Float]) {
        lock.withLock {
            for x in s {
                buf[(readPos + available) % buf.count] = x
                if available < buf.count { available += 1 } else { readPos = (readPos + 1) % buf.count }
            }
            if available > cushion * 3 {
                let drop = available - cushion
                readPos = (readPos + drop) % buf.count
                available -= drop
            }
        }
    }

    func read(into out: UnsafeMutablePointer<Float>, count: Int) {
        lock.withLock {
            let n = min(count, available)
            for i in 0..<n { out[i] = buf[(readPos + i) % buf.count] }
            for i in n..<count { out[i] = 0 }
            readPos = (readPos + n) % buf.count
            available -= n
        }
    }
}

final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Float = 0
    private var _peak: Float = 0
    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue; _peak = max(_peak, newValue) } }
    }
    var peak: Float { lock.withLock { _peak } }
    func reset() { lock.withLock { _peak = 0 } }
}
#endif
