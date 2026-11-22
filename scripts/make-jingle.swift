// Synthesizes Sing!'s results jingle and the soft loop that follows it.
// Usage: swift scripts/make-jingle.swift <output folder>
// Writes jingle.wav and results-bed.wav (the bed loops seamlessly); convert them with afconvert.
import AVFoundation
import Foundation

let sr = 44100.0
let bpm = 124.0
let beat = 60 / bpm

func midiHz(_ n: Double) -> Double { 440 * pow(2, (n - 69) / 12) }

struct Track {
    var l: [Float]
    var r: [Float]
    let wrap: Bool
    init(seconds: Double, wrap: Bool) {
        let n = Int(seconds * sr)
        l = .init(repeating: 0, count: n)
        r = .init(repeating: 0, count: n)
        self.wrap = wrap
    }
    var count: Int { l.count }
    mutating func add(_ i: Int, _ v: Double, pan: Double = 0) {
        var j = i
        if j >= count { guard wrap else { return }; j %= count }
        guard j >= 0 else { return }
        l[j] += Float(v * (1 - max(0, pan)))
        r[j] += Float(v * (1 + min(0, pan)))
    }
}

var seed: UInt64 = 0x5eed
func noise() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1
}

/// Bright detuned saw with a closing low-pass: the "brass" of the jingle.
func brass(_ t: inout Track, at: Double, note: Double, dur: Double, amp: Double, pan: Double = 0) {
    let start = Int(at * sr), len = Int((dur + 0.35) * sr)
    var lp = 0.0
    for k in 0..<len {
        let x = Double(k) / sr
        let attack = min(1, x / 0.012)
        let release = x > dur ? exp(-(x - dur) * 12) : 1
        let env = attack * release * (0.75 + 0.25 * exp(-x * 5))
        var s = 0.0
        for d in [-0.07, 0.0, 0.07] {
            let ph = (x * midiHz(note + d)).truncatingRemainder(dividingBy: 1)
            s += 2 * ph - 1
        }
        let cutoff = 900 + 5200 * exp(-x * 4)
        let a = 1 - exp(-2 * .pi * cutoff / sr)
        lp += a * (s / 3 - lp)
        t.add(start + k, lp * env * amp, pan: pan)
    }
}

/// Electric-piano chord tone: sine with a soft bell partial.
func keys(_ t: inout Track, at: Double, note: Double, dur: Double, amp: Double, pan: Double = 0) {
    let start = Int(at * sr), len = Int((dur + 0.6) * sr)
    let f = midiHz(note)
    for k in 0..<len {
        let x = Double(k) / sr
        let env = min(1, x / 0.006) * exp(-x * 2.2) * (x > dur ? exp(-(x - dur) * 7) : 1)
        let s = sin(2 * .pi * f * x) + 0.28 * sin(2 * .pi * f * 2 * x) * exp(-x * 6) + 0.1 * sin(2 * .pi * f * 3.01 * x) * exp(-x * 9)
        t.add(start + k, s * env * amp, pan: pan)
    }
}

func bass(_ t: inout Track, at: Double, note: Double, dur: Double, amp: Double) {
    let start = Int(at * sr), len = Int((dur + 0.1) * sr)
    let f = midiHz(note)
    for k in 0..<len {
        let x = Double(k) / sr
        let env = min(1, x / 0.01) * (x > dur ? exp(-(x - dur) * 30) : 1) * (0.7 + 0.3 * exp(-x * 4))
        let s = sin(2 * .pi * f * x) + 0.25 * sin(2 * .pi * 2 * f * x)
        t.add(start + k, s * env * amp)
    }
}

func kick(_ t: inout Track, at: Double, amp: Double) {
    let start = Int(at * sr)
    var ph = 0.0
    for k in 0..<Int(0.35 * sr) {
        let x = Double(k) / sr
        ph += (48 + 110 * exp(-x * 30)) / sr
        t.add(start + k, sin(2 * .pi * ph) * exp(-x * 9) * amp)
    }
}

func snare(_ t: inout Track, at: Double, amp: Double, decay: Double = 18) {
    let start = Int(at * sr)
    var hp = 0.0, prev = 0.0
    for k in 0..<Int(0.3 * sr) {
        let x = Double(k) / sr
        let n = noise()
        hp = 0.6 * (hp + n - prev); prev = n
        let tone = sin(2 * .pi * 190 * x) * exp(-x * 25)
        t.add(start + k, (hp * 0.8 + tone * 0.5) * exp(-x * decay) * amp)
    }
}

func hat(_ t: inout Track, at: Double, amp: Double, pan: Double = 0.3) {
    let start = Int(at * sr)
    var hp = 0.0, prev = 0.0
    for k in 0..<Int(0.08 * sr) {
        let x = Double(k) / sr
        let n = noise()
        hp = 0.3 * (hp + n - prev); prev = n
        t.add(start + k, hp * exp(-x * 60) * amp, pan: pan)
    }
}

func cymbal(_ t: inout Track, at: Double, amp: Double) {
    let start = Int(at * sr)
    var hp = 0.0, prev = 0.0
    for k in 0..<Int(2.2 * sr) {
        let x = Double(k) / sr
        let n = noise()
        hp = 0.45 * (hp + n - prev); prev = n
        t.add(start + k, hp * exp(-x * 2.2) * amp, pan: k % 2 == 0 ? 0.3 : -0.3)
    }
}

/// Short Schroeder-style room so the synths sound less dry.
func room(_ t: inout Track, mix: Double) {
    let delays = [1557, 1617, 1491, 1422].map { $0 }
    for (ch, src) in [t.l, t.r].enumerated() {
        var out = src
        for (i, d) in delays.enumerated() {
            var buf = [Double](repeating: 0, count: d)
            var idx = 0
            for k in 0..<src.count {
                let y = buf[idx]
                buf[idx] = Double(src[k]) + y * 0.78
                idx = (idx + 1) % d
                out[k] += Float(y * mix / Double(delays.count) * (i % 2 == ch ? 1 : 0.8))
            }
        }
        if ch == 0 { t.l = out } else { t.r = out }
    }
}

func normalize(_ t: inout Track, peak: Double) {
    let m = max(t.l.map(abs).max() ?? 1, t.r.map(abs).max() ?? 1)
    let g = Float(peak) / max(m, 1e-6)
    for i in 0..<t.count { t.l[i] = tanh(t.l[i] * g * 1.1) / tanh(1.1); t.r[i] = tanh(t.r[i] * g * 1.1) / tanh(1.1) }
}

func write(_ t: Track, to url: URL) throws {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(t.count))!
    buf.frameLength = AVAudioFrameCount(t.count)
    for i in 0..<t.count { buf.floatChannelData![0][i] = t.l[i]; buf.floatChannelData![1][i] = t.r[i] }
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
    try file.write(from: buf)
}

// MARK: Jingle: a rising run, two pushes, and a big major chord (about 4 s).
var j = Track(seconds: 4.4, wrap: false)
let s16 = beat / 4
let run: [Double] = [60, 64, 67, 72, 76, 79]
for (i, n) in run.enumerated() {
    brass(&j, at: Double(i) * s16, note: n, dur: s16 * 0.9, amp: 0.32, pan: i % 2 == 0 ? -0.2 : 0.2)
}
for i in 0..<6 { snare(&j, at: Double(i) * s16, amp: 0.08 + 0.03 * Double(i), decay: 26) }
let push1 = 6 * s16, push2 = push1 + beat * 0.75, hit = push2 + beat * 0.75
for n in [65.0, 69, 72, 77] { brass(&j, at: push1, note: n, dur: beat * 0.5, amp: 0.2) }
for n in [67.0, 71, 74, 79] { brass(&j, at: push2, note: n, dur: beat * 0.5, amp: 0.2) }
kick(&j, at: push1, amp: 0.7); snare(&j, at: push1, amp: 0.35)
kick(&j, at: push2, amp: 0.7); snare(&j, at: push2, amp: 0.35)
bass(&j, at: push1, note: 41, dur: beat * 0.6, amp: 0.4)
bass(&j, at: push2, note: 43, dur: beat * 0.6, amp: 0.4)
for (i, n) in [60.0, 64, 67, 72, 76, 79, 84].enumerated() {
    brass(&j, at: hit, note: n, dur: 1.9, amp: 0.17, pan: Double(i - 3) * 0.12)
}
keys(&j, at: hit, note: 88, dur: 1.2, amp: 0.12)
kick(&j, at: hit, amp: 0.9); snare(&j, at: hit, amp: 0.45, decay: 10); cymbal(&j, at: hit, amp: 0.35)
bass(&j, at: hit, note: 36, dur: 1.8, amp: 0.5)
room(&j, mix: 0.22)
normalize(&j, peak: 0.89)
let fadeLen = Int(0.25 * sr)
for k in 0..<fadeLen { let g = Float(Double(fadeLen - k) / Double(fadeLen)); j.l[j.count - fadeLen + k] *= g; j.r[j.count - fadeLen + k] *= g }

// MARK: Bed: eight bars of C, Am, F, G at the same tempo, soft enough to talk over. Loops seamlessly.
let bar = beat * 4
var b = Track(seconds: bar * 8, wrap: true)
let chords: [(root: Double, tones: [Double])] = [(36, [64, 67, 72]), (33, [64, 69, 72]), (29, [65, 69, 72]), (31, [62, 67, 71])]
for barIndex in 0..<8 {
    let c = chords[barIndex / 2]
    let t0 = Double(barIndex) * bar
    for step in [0.5, 1.5, 2.5, 3.25] {
        for (i, n) in c.tones.enumerated() { keys(&b, at: t0 + step * beat, note: n, dur: beat * 0.45, amp: 0.1, pan: Double(i - 1) * 0.25) }
    }
    bass(&b, at: t0, note: c.root, dur: beat * 1.4, amp: 0.42)
    bass(&b, at: t0 + beat * 1.5, note: c.root + 12, dur: beat * 0.4, amp: 0.25)
    bass(&b, at: t0 + beat * 2, note: c.root, dur: beat * 1.4, amp: 0.38)
    bass(&b, at: t0 + beat * 3.5, note: c.root + 7, dur: beat * 0.4, amp: 0.25)
    for k in 0..<4 { kick(&b, at: t0 + Double(k) * beat, amp: k % 2 == 0 ? 0.5 : 0.3) }
    snare(&b, at: t0 + beat, amp: 0.13, decay: 22); snare(&b, at: t0 + 3 * beat, amp: 0.13, decay: 22)
    for k in 0..<8 { hat(&b, at: t0 + Double(k) * beat / 2, amp: k % 2 == 0 ? 0.1 : 0.16) }
    // A small melody on the second bar of each chord, so the loop has a hook.
    if barIndex % 2 == 1 {
        let top = c.tones.last! + 12
        for (i, d) in [0.0, -3, -5, -3].enumerated() { keys(&b, at: t0 + Double(i) * beat * 0.75, note: top + d, dur: beat * 0.5, amp: 0.07, pan: 0.35) }
    }
}
room(&b, mix: 0.18)
normalize(&b, peak: 0.6)

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try write(j, to: out.appendingPathComponent("jingle.wav"))
try write(b, to: out.appendingPathComponent("results-bed.wav"))
print("jingle \(String(format: "%.2f", Double(j.count) / sr)) s, bed \(String(format: "%.2f", Double(b.count) / sr)) s")
