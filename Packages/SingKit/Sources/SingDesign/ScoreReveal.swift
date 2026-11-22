import SwiftUI
import SingCore

/// The end-of-song scene: the score builds in a ring, then the details arrive one by one.
struct ScoreRevealStage: View {
    var result: PerformanceResult
    var settings: TVDisplaySettings
    var scale: CGFloat
    @State private var shown = false
    @Environment(\.singTheme) private var theme

    private var color: Color { result.singers.first?.color ?? theme.accent }

    var body: some View {
        TimelineView(.animation) { ctx in
            let elapsed = ctx.date.timeIntervalSince(result.endedAt)
            ZStack {
                if settings.showConfetti, (result.total ?? 0) >= 60 {
                    Confetti(elapsed: elapsed, colors: [color, theme.accent, theme.accentSoft, .white, .yellow], scale: scale)
                }
                HStack(alignment: .center, spacing: 90 * scale) {
                    left(elapsed)
                        .frame(width: 620 * scale)
                    if settings.showScoreDetails, result.total != nil {
                        right(elapsed)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let url = result.shareURL {
                    HStack(spacing: 16 * scale) {
                        VStack(alignment: .trailing, spacing: 4 * scale) {
                            Text("Take your performance home").font(.system(size: 24 * scale, weight: .semibold))
                            Text("Scan on the same Wi-Fi").font(.system(size: 19 * scale)).opacity(0.7)
                        }
                        QRCodeView(url).padding(10 * scale).background(.white, in: RoundedRectangle(cornerRadius: 16 * scale)).frame(width: 150 * scale, height: 150 * scale)
                    }
                    .foregroundStyle(theme.text)
                    .padding(40 * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .opacity(appear(elapsed, at: 1.5))
                }
            }
        }
    }

    private func appear(_ elapsed: Double, at t: Double) -> Double { max(0, min(1, (elapsed - t) / 0.8)) }

    @ViewBuilder private func left(_ elapsed: Double) -> some View {
        let total = result.total
        let countUp = total.map { Int(Double($0) * easeOut(min(1, max(0, (elapsed - 0.8) / 2.2)))) }
        VStack(spacing: 22 * scale) {
            HStack(spacing: 14 * scale) {
                ForEach(result.singers) { s in
                    HStack(spacing: 10 * scale) {
                        Circle().fill(s.color).frame(width: 18 * scale, height: 18 * scale)
                        Text(s.name)
                    }
                }
            }
            .font(.system(size: 32 * scale, weight: .bold))
            .reveal(appear(elapsed, at: 0.2))
            if let clap = result.applause, settings.showApplause {
                HStack(spacing: 12 * scale) {
                    Text("👏")
                    Capsule().fill(.white.opacity(0.15)).frame(width: 260 * scale, height: 14 * scale)
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 260 * scale * CGFloat(clap) / 100, height: 14 * scale) }
                    Text("\(clap)").monospacedDigit()
                }
                .font(.system(size: 30 * scale, weight: .bold))
                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: clap)
            }
            if let parts = result.perSinger, parts.count > 1 {
                HStack(spacing: 30 * scale) {
                    ForEach(parts) { p in
                        VStack(spacing: 2 * scale) {
                            Text("\(p.count)").font(.system(size: 48 * scale, weight: .black, design: .rounded)).monospacedDigit()
                            Text(p.name).font(.system(size: 22 * scale, weight: .semibold)).opacity(0.8)
                        }
                        .foregroundStyle(p.colorHex.map { Color(hex: $0) } ?? theme.text)
                    }
                }
                .opacity(appear(elapsed, at: 3))
            }
            if let total, let countUp {
                ZStack {
                    Circle().fill(.white).blur(radius: 90 * scale).opacity(0.22).padding(60 * scale)
                    Circle().stroke(.white.opacity(0.14), lineWidth: 6 * scale)
                    Circle()
                        .trim(from: 0, to: CGFloat(countUp) / 100)
                        .stroke(.white, style: StrokeStyle(lineWidth: 6 * scale, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(countUp)").font(.system(size: 220 * scale, weight: .black, design: .rounded)).monospacedDigit()
                        Text("Grade \(result.grade ?? ScoreKeeper.grade(total))").font(.system(size: 28 * scale, weight: .bold)).opacity(0.75)
                    }
                }
                .frame(width: 460 * scale, height: 460 * scale)
                .scaleEffect(0.6 + 0.4 * easeOut(appear(elapsed, at: 0.5)))
                .reveal(appear(elapsed, at: 0.5))
            } else {
                Text("Bravo!").font(.system(size: 180 * scale, weight: .black, design: .rounded)).reveal(appear(elapsed, at: 0.4))
            }
            Text(result.title).font(.system(size: 60 * scale, weight: .black)).reveal(appear(elapsed, at: 2.6))
            Text(result.comment).font(.system(size: 24 * scale)).opacity(0.8).multilineTextAlignment(.center).reveal(appear(elapsed, at: 3.0))
        }
    }

    @ViewBuilder private func right(_ elapsed: Double) -> some View {
        VStack(alignment: .leading, spacing: 22 * scale) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20 * scale), count: 3), spacing: 20 * scale) {
                ForEach(Array(result.categories.enumerated()), id: \.offset) { i, c in
                    let a = appear(elapsed, at: 3.2 + Double(i) * 0.18)
                    VStack(alignment: .leading, spacing: 12 * scale) {
                        Text(c.name.uppercased()).font(.system(size: 17 * scale, weight: .bold)).opacity(0.75)
                        Text("\(c.value)").font(.system(size: 64 * scale, weight: .black, design: .rounded))
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.16)).overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: g.size.width * CGFloat(c.value) / 100 * easeOut(a))
                            }
                        }
                        .frame(height: 8 * scale)
                        Text(c.note).font(.system(size: 17 * scale)).opacity(0.7).lineLimit(2)
                    }
                    .padding(24 * scale)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30 * scale))
                    .reveal(a)
                }
            }
            if !result.badges.isEmpty {
                HStack(spacing: 14 * scale) {
                    ForEach(result.badges, id: \.self) { b in
                        Text(b).font(.system(size: 22 * scale, weight: .bold))
                            .padding(.horizontal, 24 * scale).padding(.vertical, 12 * scale)
                            .glassEffect(.regular.tint(color.opacity(0.4)), in: .capsule)
                    }
                }
                .reveal(appear(elapsed, at: 4.4))
            }
            if !result.leaderboard.isEmpty {
                HStack(spacing: 36 * scale) {
                    Text("TONIGHT").font(.system(size: 17 * scale, weight: .bold)).opacity(0.75)
                    ForEach(Array(result.leaderboard.prefix(4).enumerated()), id: \.offset) { i, r in
                        HStack(spacing: 10 * scale) {
                            Text("\(i + 1)").opacity(0.6).fontWeight(.heavy)
                            if let hex = r.colorHex { Circle().fill(Color(hex: hex)).frame(width: 14 * scale, height: 14 * scale) }
                            Text(r.name).fontWeight(i == 0 ? .heavy : .medium)
                            Text("\(r.count)").fontWeight(.heavy)
                        }
                    }
                }
                .font(.system(size: 24 * scale))
                .padding(24 * scale)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30 * scale))
                .reveal(appear(elapsed, at: 4.8))
            }
        }
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}

private extension View {
    func reveal(_ a: Double) -> some View {
        opacity(a).offset(y: (1 - a) * 30).blur(radius: (1 - a) * 10)
    }
}

struct Confetti: View {
    var elapsed: Double
    var colors: [Color]
    var scale: CGFloat

    var body: some View {
        Canvas { ctx, size in
            for i in 0..<60 {
                let seed = Double(i) * 12.9898
                let x = (sin(seed) * 0.5 + 0.5) * size.width
                let speed = 140 + (sin(seed * 3.1) * 0.5 + 0.5) * 160
                let delay = (sin(seed * 7.7) * 0.5 + 0.5) * 3
                let t = elapsed - delay
                guard t > 0 else { continue }
                let y = (t * speed * Double(scale)).truncatingRemainder(dividingBy: Double(size.height) + 60) - 30
                let rot = t * (2 + sin(seed) * 2)
                var c = ctx
                c.translateBy(x: x + sin(t * 2 + seed) * 20, y: y)
                c.rotate(by: .radians(rot))
                c.fill(Path(roundedRect: CGRect(x: -6 * scale, y: -11 * scale, width: 12 * scale, height: 22 * scale), cornerRadius: 3), with: .color(colors[i % colors.count].opacity(0.85)))
            }
        }
        .allowsHitTesting(false)
    }
}
