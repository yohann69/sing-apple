import SwiftUI

/// Slowly drifting blurred blobs in the artwork colors, cross-fading when the palette changes.
public struct BlobBackground: View {
    var colors: [Color]
    var base: Color
    var period: Double
    var dim: Double

    public init(colors: [Color], base: Color = .black, period: Double = 28, dim: Double = 0.3) {
        self.colors = colors.isEmpty ? [.orange, .red, .yellow, .purple] : colors
        self.base = base
        self.period = max(4, period)
        self.dim = dim
    }

    private static let seeds: [(x: Double, y: Double, r: Double, fx: Double, fy: Double, phase: Double)] = [
        (0.15, 0.10, 0.75, 1.0, 0.8, 0.0),
        (0.85, 0.15, 0.70, 0.7, 1.1, 1.7),
        (0.30, 0.85, 0.65, 1.2, 0.9, 3.1),
        (0.80, 0.80, 0.60, 0.9, 1.3, 4.4),
        (0.50, 0.45, 0.50, 1.4, 0.6, 2.2),
    ]

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate / period * 2 * .pi
            GeometryReader { geo in
                let size = geo.size
                let unit = max(size.width, size.height)
                ZStack {
                    base
                    ForEach(Array(Self.seeds.enumerated()), id: \.offset) { i, s in
                        let color = colors[i % colors.count]
                        let dx = sin(t * s.fx + s.phase) * 0.18
                        let dy = cos(t * s.fy + s.phase * 1.3) * 0.16
                        let scale = 1 + 0.12 * sin(t * 0.7 + s.phase)
                        Circle()
                            .fill(color)
                            .frame(width: unit * s.r, height: unit * s.r)
                            .scaleEffect(scale)
                            .position(x: size.width * (s.x + dx), y: size.height * (s.y + dy))
                            .opacity(0.85)
                    }
                }
                .blur(radius: unit * 0.09)
                .overlay(Color.black.opacity(dim))
            }
        }
        .animation(.easeInOut(duration: 1.6), value: colors)
        .drawingGroup()
        .ignoresSafeArea()
    }
}

#Preview {
    BlobBackground(colors: SingTheme.ember.blobs, base: SingTheme.ember.background)
}
