import AVFoundation
import Network
import SingClient
import SingCore

/// Streams this device's microphone to the Mac as a wireless mic (24 kHz mono, 20 ms UDP packets).
final class PhoneMicSender: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var connection: NWConnection?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var pending = Data()
    private var seq: UInt32 = 0
    private var key = Data()
    private(set) var running = false

    func start(host: String, session: PhoneMicSession) throws {
        stop()
        key = Data(base64Encoded: session.key) ?? Data()
        let av = AVAudioSession.sharedInstance()
        try av.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try av.setPreferredIOBufferDuration(0.01)
        try av.setActive(true)
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(session.port))!, using: .udp)
        c.start(queue: .global(qos: .userInteractive))
        connection = c
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 480, format: format, block: Self.tap(self))
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        connection?.cancel()
        connection = nil
        running = false
    }

    static func tap(_ s: PhoneMicSender) -> AVAudioNodeTapBlock {
        { buf, _ in s.process(buf) }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard let ch = out.int16ChannelData?[0] else { return }
        pending.append(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        while pending.count >= 960 {
            var packet = key
            var s = seq.bigEndian
            packet.append(Data(bytes: &s, count: 4))
            packet.append(pending.prefix(960))
            pending.removeFirst(960)
            seq &+= 1
            connection?.send(content: packet, completion: .idempotent)
        }
    }
}
