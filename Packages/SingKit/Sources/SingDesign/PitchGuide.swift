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

    static let past: TimeInterval = 3
    static let future: TimeInterval = 7

    public var body: some View {
        Canvas { ctx, size in
            let playX = size.width * 0.3
            let pps = playX / Self.past
            let low = track.low, high = max(track.high, track.low + 8)
            let barH = max(8 * scale, min(22 * scale, size.height / CGFloat(high - low) * 0.9))
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
            for n in track.notes(in: (time - Self.past)...(time + Self.future)) {
                let x0 = playX + CGFloat(n.start - time) * pps
                let x1 = playX + CGFloat(n.end - time) * pps
                let rect = CGRect(x: x0, y: y(n.midi) - barH / 2, width: max(4, x1 - x0), height: barH)
                let shape = Path(roundedRect: rect, cornerRadius: barH / 2)
                if n.start <= time {
                    var glow = ctx
                    glow.addFilter(.shadow(color: color.opacity(0.7), radius: 10 * scale))
                    glow.fill(shape, with: .color(color.opacity(n.end < time ? 0.75 : 0.95)))
                } else {
                    ctx.fill(shape, with: .color(.white.opacity(0.26)))
                }
            }
            if live.count > 1 {
                var p = Path()
                var last: LivePitchPoint?
                for pt in live where pt.time <= time {
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
