#if os(macOS)
import AVFoundation
import Foundation
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
    private var instrumentalFile: AVAudioFile?
    private var vocalsFile: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var generation = 0
    private var outputUID: String?

    public private(set) var isPlaying = false
    public private(set) var duration: TimeInterval = 0
    public var onFinished: (() -> Void)?

    public var guideVocal: Double = 0 { didSet { vocals.volume = Float(guideVocal) } }
    public var volume: Double = 0.9 { didSet { stemMixer.outputVolume = Float(volume) } }

    public init() {
        engine.attach(instrumental)
        engine.attach(vocals)
        engine.attach(stemMixer)
        engine.connect(stemMixer, to: engine.mainMixerNode, format: nil)
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
        stemMixer.outputVolume = Float(volume)
        startFrame = 0
        engine.prepare()
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
            startFrame = AVAudioFramePosition(max(0, min(time, duration)) * sampleRate)
        }
    }

    public func stop() {
        isPlaying = false
        generation += 1
        instrumental.stop()
        vocals.stop()
        startFrame = 0
    }
}

/// Live microphone with reverb, routed to the chosen output on its own low-latency engine.
@MainActor
public final class MicEngine {
    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private let inputMixer = AVAudioMixerNode()
    private var aggregate: AudioDeviceID?
    private var configured = false
    public private(set) var isRunning = false
    public var level: Float { meter.value }
    /// Loudest sample since the mic started; exactly zero means macOS is feeding silence (access blocked).
    public var peakSinceStart: Float { meter.peak }
    public private(set) var deviceName: String?
    private let meter = LevelMeter()
    public let livePitch = LivePitch()
    private var inputUID: String?
    private var outputUID: String?

    public var gain: Double = 0.8 { didSet { engine.mainMixerNode.outputVolume = Float(gain) } }
    public var reverbMix: Double = 0.35 { didSet { reverb.wetDryMix = Float(reverbMix * 100) } }

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
    }

    public func configure(inputUID: String?, outputUID: String?) {
        self.inputUID = inputUID
        self.outputUID = outputUID
        if isRunning { stop(); try? start() }
    }

    public func start() throws {
        guard !isRunning else { return }
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
        let tapBlock = Self.tap(meter, pitch: livePitch, sampleRate: format.sampleRate)
        let eq = self.eq, reverb = self.reverb, engine = self.engine, inMixer = self.inputMixer, attach = !configured
        let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
        try objc {
            if attach {
                engine.attach(inMixer)
                engine.attach(eq)
                engine.attach(reverb)
            }
            engine.connect(input, to: inMixer, format: format)
            engine.connect(inMixer, to: eq, format: stereo)
            engine.connect(eq, to: reverb, format: stereo)
            engine.connect(reverb, to: mixer, format: stereo)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapBlock)
        }
        configured = true
        engine.mainMixerNode.outputVolume = Float(gain)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            if let aggregate { AudioDevices.destroyAggregate(aggregate) }
            aggregate = nil
            throw error
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        meter.value = 0
        meter.reset()
        if let aggregate { AudioDevices.destroyAggregate(aggregate) }
        aggregate = nil
    }

    nonisolated static func tap(_ meter: LevelMeter, pitch: LivePitch, sampleRate: Double) -> AVAudioNodeTapBlock {
        { @Sendable buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[i])) }
            meter.value = peak
            pitch.process(ch, count: Int(buf.frameLength), sampleRate: sampleRate)
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
