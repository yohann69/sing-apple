import Foundation

/// How a phone streams its mic to the Mac: UDP to `port`, each packet = key (8 bytes) + sequence (4 bytes, big endian) + 16-bit little-endian mono PCM.
public struct PhoneMicSession: Codable, Sendable {
    public var port: Int
    public var key: String
    public var sampleRate: Int
    public var samplesPerPacket: Int

    public init(port: Int, key: String, sampleRate: Int = 24000, samplesPerPacket: Int = 480) {
        self.port = port
        self.key = key
        self.sampleRate = sampleRate
        self.samplesPerPacket = samplesPerPacket
    }
}
