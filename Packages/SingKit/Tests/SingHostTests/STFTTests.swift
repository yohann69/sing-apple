import Foundation
import Testing
@testable import SingHost

private func floats(_ name: String) throws -> [Float] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "f32", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

@Suite struct STFTTests {
    @Test func matchesTorchAndRoundTrips() throws {
        let x = try floats("stft_signal")
        let refRe = try floats("stft_re")
        let refIm = try floats("stft_im")
        let stft = try STFT()
        let (re, im) = stft.stft(x)
        #expect(re.count == 20)
        var maxErr: Float = 0
        for f in 0..<20 {
            for k in 0...2048 {
                maxErr = max(maxErr, abs(re[f][k] - refRe[f * 2049 + k]), abs(im[f][k] - refIm[f * 2049 + k]))
            }
        }
        #expect(maxErr < 1e-3, "max error \(maxErr)")
        let back = stft.istft(re: re, im: im, length: x.count)
        var rtErr: Float = 0
        for i in 0..<x.count { rtErr = max(rtErr, abs(back[i] - x[i])) }
        #expect(rtErr < 1e-3, "roundtrip error \(rtErr)")
    }

    @Test func reflectPad() {
        #expect(STFT.reflectPad([1, 2, 3, 4], left: 2, right: 2) == [3, 2, 1, 2, 3, 4, 3, 2])
    }
}
