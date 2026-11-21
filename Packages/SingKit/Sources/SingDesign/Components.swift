import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import SingCore

public struct QRCodeView: View {
    var text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        if let cg = Self.render(text) {
            Image(decorative: cg, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("QR code to join")
        }
    }

    static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

public struct ArtworkPlaceholder: View {
    var palette: [Color]
    var symbol: String

    public init(palette: [Color], symbol: String = "music.note") {
        self.palette = palette
        self.symbol = symbol
    }

    public var body: some View {
        LinearGradient(colors: palette.isEmpty ? [.orange, .red] : Array(palette.prefix(2)), startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
    }
}

public struct ReadinessBadge: View {
    var readiness: Readiness
    var progress: Double?

    public init(_ readiness: Readiness, progress: Double? = nil) {
        self.readiness = readiness
        self.progress = progress
    }

    public var body: some View {
        HStack(spacing: 5) {
            switch readiness {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready")
            case .processing, .queuedForProcessing:
                ProgressView(value: progress ?? 0).progressViewStyle(.circular).controlSize(.mini)
                Text(progress.map { "Preparing \(Int($0 * 100))%" } ?? "Waiting")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Failed")
            case .missingFile:
                Image(systemName: "questionmark.folder.fill").foregroundStyle(.secondary)
                Text("Missing")
            case .new:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Not prepared")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

public struct SingerChip: View {
    var singer: Singer
    var compact: Bool

    public init(_ singer: Singer, compact: Bool = false) {
        self.singer = singer
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(singer.color)
                Text(singer.emoji ?? String(singer.name.prefix(1)).uppercased())
                    .font(.system(size: compact ? 10 : 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.75))
            }
            .frame(width: compact ? 18 : 24, height: compact ? 18 : 24)
            if !compact {
                Text(singer.name).font(.subheadline.weight(.semibold))
            }
        }
    }
}

public extension SongSummary {
    var paletteColors: [Color] {
        let base = (palette ?? []).map(Color.init(hex:))
        return base.isEmpty ? SingTheme.ember.blobs : base
    }

    var durationText: String {
        let s = durationMs / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

public extension Array where Element == Color {
    /// Artwork palettes are often greyish; mixing in the theme keeps the TV background lively.
    func vivid(with theme: SingTheme) -> [Color] {
        guard !isEmpty else { return theme.blobs }
        return enumerated().map { i, c in i % 2 == 1 ? c.mix(with: theme.blobs[i % theme.blobs.count], by: 0.35) : c }
    }
}
