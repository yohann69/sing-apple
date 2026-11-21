import SwiftUI
import SingCore

public struct FlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat
    public var alignment: HorizontalAlignment

    public init(spacing: CGFloat = 8, lineSpacing: CGFloat = 4, alignment: HorizontalAlignment = .leading) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.alignment = alignment
    }

    private func rows(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            if x > 0, x + s.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(i)
            x += s.width + spacing
        }
        return rows
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rs = rows(sizes, width: width)
        var h: CGFloat = 0
        var w: CGFloat = 0
        for r in rs {
            let rw = r.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(max(0, r.count - 1))
            w = max(w, rw)
            h += (r.map { sizes[$0].height }.max() ?? 0)
        }
        h += lineSpacing * CGFloat(max(0, rs.count - 1))
        return CGSize(width: proposal.width ?? w, height: h)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for r in rows(sizes, width: bounds.width) {
            let rw = r.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(max(0, r.count - 1))
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - rw
            case .center: x = bounds.midX - rw / 2
            default: x = bounds.minX
            }
            let rh = r.map { sizes[$0].height }.max() ?? 0
            for i in r {
                subviews[i].place(at: CGPoint(x: x, y: y + rh - sizes[i].height), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += rh + lineSpacing
        }
    }
}

public enum KaraokeTiming {
    public static func progress(of word: [LyricSegment], at t: TimeInterval) -> Double {
        let total = word.reduce(0) { $0 + max(1, $1.text.count) }
        var acc = 0.0
        for s in word {
            let d = max(0.001, s.end - s.start)
            let f = min(1, max(0, (t - s.start) / d))
            acc += f * Double(max(1, s.text.count))
        }
        return acc / Double(total)
    }
}

/// One lyric line whose words fill from left to right as they are sung.
public struct KaraokeLineView: View {
    var segments: [LyricSegment]
    var time: TimeInterval
    var font: Font
    var sung: Color
    var dim: Color
    var glow: Color
    var alignment: HorizontalAlignment
    var wipe: Bool
    var wordSpacing: CGFloat

    public init(segments: [LyricSegment], time: TimeInterval, font: Font, wordSpacing: CGFloat = 16, sung: Color = .white, dim: Color = .white.opacity(0.35), glow: Color = .white, alignment: HorizontalAlignment = .leading, wipe: Bool = true) {
        self.segments = segments
        self.time = time
        self.font = font
        self.sung = sung
        self.dim = dim
        self.glow = glow
        self.alignment = alignment
        self.wipe = wipe
        self.wordSpacing = wordSpacing
    }

    private var words: [[LyricSegment]] {
        var result: [[LyricSegment]] = []
        var current: [LyricSegment] = []
        for s in segments {
            current.append(s)
            if s.endsWord { result.append(current); current = [] }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public var body: some View {
        FlowLayout(spacing: wordSpacing, lineSpacing: 2, alignment: alignment) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                let p = wipe ? KaraokeTiming.progress(of: word, at: time) : (time >= (word.first?.start ?? 0) ? 1 : 0)
                WordView(text: word.map(\.text).joined(), progress: p, font: font, sung: sung, dim: dim, glow: glow)
            }
        }
    }
}

struct WordView: View {
    var text: String
    var progress: Double
    var font: Font
    var sung: Color
    var dim: Color
    var glow: Color

    var body: some View {
        let active = progress > 0 && progress < 1
        Text(text)
            .font(font)
            .foregroundStyle(dim)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .foregroundStyle(sung)
                    .shadow(color: glow.opacity(progress > 0 ? 0.45 : 0), radius: 18)
                    .mask(alignment: .leading) {
                        GeometryReader { g in
                            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                                .frame(width: g.size.width * 1.15 * progress + (progress >= 1 ? 40 : 0))
                        }
                    }
            }
            .offset(y: active ? -3 : (progress >= 1 ? -1 : 0))
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: active)
            .fixedSize()
    }
}
