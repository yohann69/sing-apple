#if os(macOS)
import AVFoundation
import Foundation
import Network

/// Phones and tablets as wireless mics: each sends 20 ms UDP packets of 24 kHz 16-bit mono,
/// prefixed with an 8-byte key handed out over HTTP and a 4-byte sequence number.
final class PhoneMicReceiver: @unchecked Sendable {
    static let sampleRate = 24000.0
    private let lock = NSLock()
    private var listener: NWListener?
    private var keys: [Data: String] = [:]
    private var lastPacket: [Data: Date] = [:]
    let ring = MonoRing()
    let pitch = LivePitch()
    let meter = LevelMeter()
    private(set) var port: UInt16 = 0

    func start(port: UInt16) throws {
        guard listener == nil else { return }
        let l = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: .global(qos: .userInteractive))
            self?.receive(c)
        }
        l.start(queue: .global(qos: .userInteractive))
        listener = l
        self.port = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// A new key for one device; it stops working when the device asks again or the Mac restarts.
    func issueKey(for padID: String) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &bytes)
        let key = Data(bytes)
        lock.withLock {
            keys = keys.filter { $0.value != padID }
            keys[key] = padID
        }
        return key
    }

    func revoke(_ padID: String) { lock.withLock { keys = keys.filter { $0.value != padID } } }

    /// Devices that were handed a key and have not stopped yet.
    var hasDevices: Bool { lock.withLock { !keys.isEmpty } }

    var activeDevices: [String] {
        lock.withLock { keys.filter { (lastPacket[$0.key] ?? .distantPast) > Date.now.addingTimeInterval(-1) }.map(\.value) }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count > 12 { self.handle(data) }
            if error == nil { self.receive(c) }
        }
    }

    private func handle(_ packet: Data) {
        let key = packet.prefix(8)
        guard lock.withLock({ keys[Data(key)] != nil }) else { return }
        lock.withLock { lastPacket[Data(key)] = .now }
        let pcm = packet.dropFirst(12)
        let count = pcm.count / 2
        var floats = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<count { floats[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        var peak: Float = 0
        for x in floats { peak = max(peak, abs(x)) }
        meter.value = peak
        floats.withUnsafeBufferPointer { pitch.process($0.baseAddress!, count: count, sampleRate: Self.sampleRate) }
        ring.write(floats)
    }
}
#endif
