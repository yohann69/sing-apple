import SwiftUI
import SingCore

/// Scrolling note bars from the reference melody, with the singer's live pitch drawn up to the playhead.
public struct PitchGuideView: View {
    var track: PitchTrack
    var time: TimeInterval
    var live: [LivePitchPoint]
    var color: Color
    var score: Int?
    var showScore: Bool
    var scale: CGFloat

    public init(track: PitchTrack, time: TimeInterval, live: [LivePitchPoint], color: Color, score: Int?, showScore: Bool, scale: CGFloat = 1) {
        self.track = track
        self.time = time
        self.live = live
        self.color = color
        self.score = score
        self.showScore = showScore
        self.scale = scale
    }

    /// Moving average so the live line shows the trend of the voice, not every wobble.
    static func smooth(_ pts: [LivePitchPoint], window: Int = 9) -> [LivePitchPoint] {
        guard pts.count > 2 else { return pts }
        var out: [LivePitchPoint] = []
        out.reserveCapacity(pts.count)
        for i in pts.indices {
            let lo = max(0, i - window / 2), hi = min(pts.count - 1, i + window / 2)
            var sum: Float = 0
            var n: Float = 0
            for j in lo...hi where abs(pts[j].time - pts[i].time) < 0.3 { sum += pts[j].midi; n += 1 }
            out.append(LivePitchPoint(time: pts[i].time, midi: sum / max(n, 1), onTarget: pts[i].onTarget))
        }
        return out
    }

    static let past: TimeInterval = 3
    static let future: TimeInterval = 7

    public var body: some View {
        Canvas { ctx, size in
            let playX = size.width * 0.3
            let pps = playX / Self.past
            let low = track.low, high = max(track.high, track.low + 8)
            let barH = max(12 * scale, min(20 * scale, size.height / CGFloat(high - low) * 0.8))
            func y(_ m: Float) -> CGFloat {
                let f = CGFloat((m - low) / (high - low))
                return size.height - barH / 2 - f * (size.height - barH)
            }
            for k in stride(from: Int(low.rounded(.up)), through: Int(high), by: 1) where k % 12 == 0 || k % 12 == 7 {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y(Float(k))))
                p.addLine(to: CGPoint(x: size.width, y: y(Float(k))))
                ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            // Contiguous pieces are drawn as one contour so slides and held notes read as a single phrase.
            let visible = Array(track.notes(in: (time - Self.past)...(time + Self.future)))
            var phrases: [[PitchNote]] = []
            for n in visible {
                if let last = phrases.last?.last, abs(n.start - last.end) < 0.02 { phrases[phrases.count - 1].append(n) } else { phrases.append([n]) }
            }
            let style = StrokeStyle(lineWidth: barH, lineCap: .round, lineJoin: .round)
            for phrase in phrases {
                var path = Path()
                for (k, n) in phrase.enumerated() {
                    let p0 = CGPoint(x: playX + CGFloat(n.start - time) * pps, y: y(n.midi))
                    let p1 = CGPoint(x: playX + CGFloat(n.end - time) * pps, y: y(n.finalMidi))
                    if k == 0 { path.move(to: p0) } else { path.addLine(to: p0) }
                    path.addLine(to: p1)
                }
                let startX = playX + CGFloat(phrase[0].start - time) * pps
                let endX = playX + CGFloat(phrase[phrase.count - 1].end - time) * pps
                ctx.stroke(path, with: .color(.white.opacity(0.28)), style: style)
                if startX < playX {
                    var sung = ctx
                    sung.clip(to: Path(CGRect(x: 0, y: 0, width: min(playX, endX + barH), height: size.height)))
                    sung.addFilter(.shadow(color: color.opacity(0.7), radius: 10 * scale))
                    sung.stroke(path, with: .color(color.opacity(0.92)), style: style)
                }
            }
            if live.count > 1 {
                var p = Path()
                var last: LivePitchPoint?
                for pt in Self.smooth(live) where pt.time <= time {
                    let pos = CGPoint(x: playX + CGFloat(pt.time - time) * pps, y: y(pt.midi))
                    if let l = last, pt.time - l.time < 0.15 { p.addLine(to: pos) } else { p.move(to: pos) }
                    last = pt
                }
                var line = ctx
                line.addFilter(.shadow(color: color.opacity(0.8), radius: 8 * scale))
                line.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round))
            }
            var head = Path()
            head.move(to: CGPoint(x: playX, y: 0))
            head.addLine(to: CGPoint(x: playX, y: size.height))
            ctx.stroke(head, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.8), .clear]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)), lineWidth: 2 * scale)
            if let cur = live.last, time - cur.time < 0.2 {
                let r = 12 * scale
                let dot = Path(ellipseIn: CGRect(x: playX - r, y: y(cur.midi) - r, width: 2 * r, height: 2 * r))
                var g = ctx
                g.addFilter(.shadow(color: color, radius: 16 * scale))
                g.fill(dot, with: .color(cur.onTarget ? color : .white))
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        .overlay(alignment: .topTrailing) {
            if showScore, let score {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(score)").font(.system(size: 44 * scale, weight: .black, design: .rounded)).contentTransition(.numericText())
                    Text("on pitch").font(.system(size: 18 * scale, weight: .semibold)).opacity(0.7)
                }
                .animation(.snappy, value: score)
                .padding(.trailing, 140 * scale)
            }
        }
    }
}
