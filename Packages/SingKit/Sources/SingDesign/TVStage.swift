import SwiftUI
import SingCore

/// Everything the TV needs for one frame, apart from the clock.
public struct TVStageModel {
    public var nowPlaying: NowPlaying
    public var lyrics: Lyrics?
    public var upNext: QueueEntry?
    public var settings: TVDisplaySettings
    public var artwork: Image?
    public var joinURL: String
    public var guestCode: String
    public var preparingProgress: Double?
    public var countdownEnd: Date?
    public var duration: TimeInterval
    public var queuePreview: [QueueEntry]
    public var pitch: PitchTrack?
    public var result: PerformanceResult?
    public var live: () -> (points: [LivePitchPoint], score: Int?) = { ([], nil) }

    public init(nowPlaying: NowPlaying, lyrics: Lyrics?, upNext: QueueEntry?, settings: TVDisplaySettings, artwork: Image?, joinURL: String, guestCode: String, preparingProgress: Double?, countdownEnd: Date?, duration: TimeInterval, queuePreview: [QueueEntry]) {
        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        self.upNext = upNext
        self.settings = settings
        self.artwork = artwork
        self.joinURL = joinURL
        self.guestCode = guestCode
        self.preparingProgress = preparingProgress
        self.countdownEnd = countdownEnd
        self.duration = duration
        self.queuePreview = queuePreview
    }
}

public struct TVStageView: View {
    var model: TVStageModel
    var time: () -> TimeInterval
    @Environment(\.singTheme) private var theme

    public init(model: TVStageModel, time: @escaping () -> TimeInterval) {
        self.model = model
        self.time = time
    }

    private var palette: [Color] {
        (model.nowPlaying.entry?.song.paletteColors ?? theme.blobs).vivid(with: theme)
    }

    public var body: some View {
        GeometryReader { geo in
            let scale = geo.size.height / 1080
            ZStack {
                background
                content(scale: scale)
                    .padding(.horizontal, 140 * scale)
                    .padding(.vertical, 80 * scale)
            }
            .environment(\.tvScale, scale)
        }
        .foregroundStyle(.white)
        .ignoresSafeArea()
    }

    @ViewBuilder private var background: some View {
        switch model.settings.background {
        case .artworkBlobs:
            BlobBackground(colors: palette, base: theme.background, period: model.settings.backgroundSpeed)
        case .artwork:
            ZStack {
                theme.background
                model.artwork?.resizable().scaledToFill().blur(radius: 60).opacity(0.6)
                Color.black.opacity(0.35)
            }.ignoresSafeArea()
        case .plain:
            theme.background.ignoresSafeArea()
        }
    }

    @ViewBuilder private func content(scale: CGFloat) -> some View {
        switch model.nowPlaying.state {
        case .idle:
            IdleStage(model: model, scale: scale).transition(.blurFade)
        case .preparing:
            PreparingStage(model: model, scale: scale).transition(.blurFade)
        case .countdown:
            CountdownStage(model: model, scale: scale).transition(.blurFade)
        case .finished:
            if model.settings.showScoreReveal, let r = model.result {
                ScoreRevealStage(result: r, settings: model.settings, scale: scale).transition(.blurFade)
            } else {
                FinishedStage(model: model, scale: scale).transition(.blurFade)
            }
        case .playing, .paused:
            SingingStage(model: model, time: time, scale: scale).transition(.blurFade)
        }
    }
}

private struct TVScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var tvScale: CGFloat {
        get { self[TVScaleKey.self] }
        set { self[TVScaleKey.self] = newValue }
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
    }
}

struct BlurFade: ViewModifier {
    var amount: Double
    func body(content: Content) -> some View {
        content.opacity(1 - amount).blur(radius: 18 * amount).scaleEffect(1 - 0.04 * amount)
    }
}

// MARK: Singing

struct SingingStage: View {
    var model: TVStageModel
    var time: () -> TimeInterval
    var scale: CGFloat
    @Environment(\.singTheme) private var theme

    var body: some View {
        TimelineView(.animation) { _ in
            let t = time()
            VStack(alignment: .leading, spacing: 0) {
                topBar(t)
                Spacer(minLength: 0)
                if let lyrics = model.lyrics, lyrics.kind != .plain {
                    LyricsColumn(lyrics: lyrics, time: t, settings: model.settings, singers: model.nowPlaying.entry?.singers ?? [], scale: scale)
                } else if let lyrics = model.lyrics {
                    PlainLyrics(lyrics: lyrics, progress: model.duration > 0 ? t / model.duration : 0, scale: scale)
                } else {
                    Text("No lyrics for this song yet")
                        .font(theme.lyricFont(size: 56 * scale))
                        .opacity(0.6)
                }
                Spacer(minLength: 0)
                if model.settings.showPitchGuide, let track = model.pitch {
                    let live = model.live()
                    PitchGuideView(track: track, time: t, live: live.points, color: model.nowPlaying.entry?.singers.first?.color ?? theme.accent, score: live.score, showScore: model.settings.showLiveScore, scale: scale)
                        .frame(height: 210 * scale)
                        .padding(.horizontal, -140 * scale)
                        .padding(.bottom, 18 * scale)
                        .transition(.opacity)
                }
                if model.settings.showProgress {
                    ProgressLine(progress: model.duration > 0 ? t / model.duration : 0)
                        .frame(height: 4 * scale)
                }
            }
            .overlay {
                if model.nowPlaying.state == .paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 90 * scale, weight: .bold))
                        .padding(50 * scale)
                        .glassEffect(.regular, in: .circle)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder private func topBar(_ t: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 20 * scale) {
            if model.settings.showSongInfo, let song = model.nowPlaying.entry?.song {
                Group {
                    if let art = model.artwork { art.resizable().scaledToFill() } else { ArtworkPlaceholder(palette: song.paletteColors) }
                }
                .frame(width: 64 * scale, height: 64 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 12 * scale))
                .shadow(color: .black.opacity(0.35), radius: 15 * scale, y: 6 * scale)
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(song.title).font(.system(size: 24 * scale, weight: .bold))
                    Text(song.artist).font(.system(size: 20 * scale)).opacity(0.7)
                }
                .lineLimit(1)
            }
            Spacer()
            if model.settings.showUpNext, let next = model.upNext {
                HStack(spacing: 12 * scale) {
                    if let s = next.singers.first { SingerChip(s, compact: true).scaleEffect(1.6 * scale) }
                    Text("Next").opacity(0.7)
                    Text(next.singers.map(\.name).joined(separator: " & ").nilIfEmpty ?? next.song.title).fontWeight(.bold)
                }
                .font(.system(size: 20 * scale))
                .padding(.horizontal, 20 * scale)
                .padding(.vertical, 12 * scale)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .opacity(0.9)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct ProgressLine: View {
    var progress: Double
    var body: some View {
        GeometryReader { g in
            Capsule().fill(.white.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.85)).frame(width: g.size.width * min(1, max(0, progress)))
                }
        }
    }
}

/// Apple Music style column: every line keeps its size, the column glides so the sung line sits
/// at the same height, lines follow each other in a short wave, and distance adds blur and fade.
struct LyricsColumn: View {
    var lyrics: Lyrics
    var time: TimeInterval
    var settings: TVDisplaySettings
    var singers: [Singer]
    var scale: CGFloat
    @Environment(\.singTheme) private var theme
    @State private var heights: [Int: CGFloat] = [:]

    private var agentOrder: [String] {
        var seen: [String] = []
        let groups = Set(lyrics.agents.filter(\.isGroup).map(\.id))
        for l in lyrics.lines { if let a = l.agent, !groups.contains(a), !seen.contains(a) { seen.append(a) } }
        return seen
    }

    private func isGroup(_ agent: String?) -> Bool {
        guard let agent else { return false }
        return lyrics.agents.contains { $0.id == agent && $0.isGroup }
    }

    private func alignment(_ line: LyricLine) -> HorizontalAlignment {
        guard lyrics.isDuet, let a = line.agent, !isGroup(a) else { return .leading }
        return agentOrder.firstIndex(of: a) == 1 ? .trailing : .leading
    }

    private func singer(for line: LyricLine) -> Singer? {
        guard lyrics.isDuet else { return singers.first }
        if isGroup(line.agent) { return nil }
        guard let a = line.agent, let i = agentOrder.firstIndex(of: a), singers.indices.contains(i) else { return singers.first }
        return singers[i]
    }

    /// The line to centre on: the one being sung, or the next one during a break.
    private func focusIndex() -> Int {
        let lines = lyrics.lines
        guard let i = lyrics.lineIndex(at: time + 0.25) else { return 0 }
        if time > lines[i].end + 0.4, i + 1 < lines.count { return i + 1 }
        return i
    }

    var body: some View {
        let lines = lyrics.lines
        let focus = focusIndex()
        let size = settings.lyricSize * scale
        let spacing = size * 0.42
        let before = settings.showPreviousLine ? 2 : 0
        let after = settings.showNextLine ? 3 : 0
        let range = max(0, focus - before)...min(lines.count - 1, focus + after)
        let focusLine = lines[focus]
        let waiting = time < focusLine.start - 0.2
        let gap = focusLine.start - time
        let prevEnd = focus > 0 ? lines[focus - 1].end : 0
        let showDots = settings.showCountdown && waiting && gap < 4 && (focusLine.start - prevEnd > 5 || focus == 0)

        GeometryReader { geo in
            let anchor = geo.size.height * 0.36
            ZStack(alignment: .topLeading) {
                ForEach(Array(range), id: \.self) { i in
                    let line = lines[i]
                    let d = i - focus
                    let y = anchor + offset(of: i, focus: focus, spacing: spacing, fallback: size * 1.3)
                    lineView(line, isFocus: i == focus && !waiting, distance: d, size: size)
                        .frame(width: geo.size.width, alignment: Alignment(horizontal: alignment(line), vertical: .top))
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                            if abs((heights[i] ?? 0) - h) > 0.5 { heights[i] = h }
                        }
                        .offset(y: y)
                        .opacity(opacity(d, waiting: waiting))
                        .blur(radius: (d == 0 && !waiting) ? 0 : min(7, CGFloat(abs(d)) * 2.2 + (waiting && d == 0 ? 0.8 : 0)) * scale)
                        .scaleEffect(d == 0 && !waiting ? 1 : 0.97, anchor: alignment(line) == .trailing ? .trailing : .leading)
                        .animation(.spring(response: 0.85, dampingFraction: 0.86).delay(Double(max(0, d)) * 0.045), value: focus)
                        .animation(.easeInOut(duration: 0.5), value: waiting)
                        .transition(.opacity.combined(with: .offset(y: d > 0 ? 60 * scale : -60 * scale)))
                }
                if showDots {
                    CountdownDots(remaining: gap, scale: scale)
                        .offset(y: anchor - 60 * scale)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .animation(.easeInOut(duration: 0.4), value: showDots)
        }
    }

    private func opacity(_ d: Int, waiting: Bool) -> Double {
        if d == 0 { return waiting ? 0.75 : 1 }
        if d > 0 { return max(0.12, 0.5 - Double(d - 1) * 0.14) }
        return max(0.08, 0.32 - Double(-d - 1) * 0.14)
    }

    private func offset(of i: Int, focus: Int, spacing: CGFloat, fallback: CGFloat) -> CGFloat {
        if i == focus { return 0 }
        var y: CGFloat = 0
        if i > focus {
            for k in focus..<i { y += (heights[k] ?? fallback) + spacing }
        } else {
            for k in i..<focus { y -= (heights[k] ?? fallback) + spacing }
        }
        return y
    }

    @ViewBuilder private func label(_ line: LyricLine, size: CGFloat) -> some View {
        if settings.showSingerNames, lyrics.isDuet || singers.count > 1 {
            if let s = singer(for: line) {
                HStack(spacing: 12 * scale) {
                    Circle().fill(s.color).frame(width: 14 * scale, height: 14 * scale)
                    Text(s.name)
                }
                .font(.system(size: max(18, size * 0.26), weight: .bold))
            } else if isGroup(line.agent) {
                Text(singers.map(\.name).joined(separator: " & ")).font(.system(size: max(18, size * 0.26), weight: .bold))
            }
        }
    }

    private func lineView(_ line: LyricLine, isFocus: Bool, distance: Int, size: CGFloat) -> some View {
        let align = alignment(line)
        let color = lyrics.isDuet ? (singer(for: line)?.color ?? .white) : (singers.first?.color ?? .white)
        let wipe = lyrics.kind >= .word || settings.estimatedWordWipe
        let t = distance < 0 ? max(time, line.end + 1) : (distance > 0 ? min(time, line.start - 1) : time)
        return VStack(alignment: align, spacing: 10 * scale) {
            label(line, size: size)
            KaraokeLineView(segments: line.segments, time: t, font: theme.lyricFont(size: size), wordSpacing: size * 0.26,
                            sung: .white, dim: .white.opacity(isFocus ? 0.32 : 1), glow: color.mix(with: .white, by: 0.35), alignment: align, wipe: wipe && isFocus)
            if settings.showBackingVocals, !line.background.isEmpty {
                KaraokeLineView(segments: line.background, time: t, font: theme.lyricFont(size: size * 0.42).italic(), wordSpacing: size * 0.1,
                                sung: .white.opacity(0.9), dim: .white.opacity(isFocus ? 0.28 : 0.8), glow: color, alignment: align, wipe: wipe && isFocus)
            }
            if settings.showTranslation, let tr = line.translation {
                Text(tr).font(.system(size: size * 0.34, weight: .semibold)).opacity(0.6)
            }
        }
    }
}

struct CountdownDots: View {
    var remaining: TimeInterval
    var scale: CGFloat

    var body: some View {
        HStack(spacing: 22 * scale) {
            ForEach(0..<3) { i in
                let lit = remaining > Double(i) * 1.2
                Circle()
                    .fill(.white)
                    .frame(width: 26 * scale, height: 26 * scale)
                    .opacity(lit ? 0.95 : 0.18)
                    .scaleEffect(lit ? 1 : 0.7)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: lit)
            }
        }
    }
}

struct PlainLyrics: View {
    var lyrics: Lyrics
    var progress: Double
    var scale: CGFloat
    @Environment(\.singTheme) private var theme

    var body: some View {
        let i = min(lyrics.lines.count - 1, max(0, Int(Double(lyrics.lines.count) * progress)))
        VStack(alignment: .leading, spacing: 20 * scale) {
            ForEach(lyrics.lines[i..<min(lyrics.lines.count, i + 3)]) { l in
                Text(l.text).font(theme.lyricFont(size: 64 * scale)).opacity(l.id == i ? 1 : 0.4)
            }
        }
        .animation(.spring(response: 0.7, dampingFraction: 0.85), value: i)
    }
}

// MARK: Other states

struct IdleStage: View {
    var model: TVStageModel
    var scale: CGFloat
    @Environment(\.singTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 90 * scale) {
            VStack(alignment: .leading, spacing: 24 * scale) {
                Text("Sing!")
                    .font(.system(size: 150 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [theme.accentSoft, theme.accent], startPoint: .top, endPoint: .bottom))
                Text(model.queuePreview.isEmpty ? "Pick a song on your phone or tablet to start." : "Up next")
                    .font(.system(size: 38 * scale, weight: .semibold))
                    .opacity(0.85)
                ForEach(model.queuePreview.prefix(4)) { e in
                    HStack(spacing: 16 * scale) {
                        if let s = e.singers.first { SingerChip(s, compact: true).scaleEffect(1.7 * scale) }
                        Text(e.song.title).fontWeight(.bold)
                        Text(e.song.artist).opacity(0.6)
                    }
                    .font(.system(size: 30 * scale))
                }
            }
            Spacer()
            if model.settings.showJoinQR {
                VStack(spacing: 20 * scale) {
                    QRCodeView(model.joinURL)
                        .padding(24 * scale)
                        .background(.white, in: RoundedRectangle(cornerRadius: 28 * scale))
                        .frame(width: 340 * scale, height: 340 * scale)
                    Text("Scan to join").font(.system(size: 30 * scale, weight: .bold))
                    Text("or enter code \(model.guestCode)").font(.system(size: 24 * scale, weight: .medium, design: .monospaced)).opacity(0.75)
                }
                .padding(36 * scale)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 44 * scale))
            }
        }
    }
}

struct PreparingStage: View {
    var model: TVStageModel
    var scale: CGFloat

    var body: some View {
        VStack(spacing: 34 * scale) {
            if let song = model.nowPlaying.entry?.song {
                Group {
                    if let a = model.artwork { a.resizable().scaledToFill() } else { ArtworkPlaceholder(palette: song.paletteColors) }
                }
                .frame(width: 320 * scale, height: 320 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 36 * scale))
                .shadow(color: .black.opacity(0.4), radius: 40 * scale, y: 20 * scale)
                Text(song.title).font(.system(size: 64 * scale, weight: .heavy))
                Text(song.artist).font(.system(size: 34 * scale, weight: .semibold)).opacity(0.7)
                HStack(spacing: 16 * scale) {
                    ProgressView(value: model.preparingProgress ?? 0)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 420 * scale)
                    Text("Preparing \(Int((model.preparingProgress ?? 0) * 100))%")
                        .font(.system(size: 26 * scale, weight: .semibold))
                        .monospacedDigit()
                }
                .padding(.top, 20 * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CountdownStage: View {
    var model: TVStageModel
    var scale: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let remaining = max(0, (model.countdownEnd ?? ctx.date).timeIntervalSince(ctx.date))
            VStack(spacing: 30 * scale) {
                if let entry = model.nowPlaying.entry {
                    if !entry.singers.isEmpty {
                        Text(entry.singers.map(\.name).joined(separator: " & "))
                            .font(.system(size: 54 * scale, weight: .heavy))
                    }
                    Text("\(entry.song.title) · \(entry.song.artist)")
                        .font(.system(size: 32 * scale, weight: .semibold)).opacity(0.75)
                }
                Text("\(Int(ceil(remaining)))")
                    .font(.system(size: 260 * scale, weight: .black, design: .rounded))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: Int(ceil(remaining)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct FinishedStage: View {
    var model: TVStageModel
    var scale: CGFloat

    var body: some View {
        VStack(spacing: 24 * scale) {
            Text("Bravo!").font(.system(size: 160 * scale, weight: .black, design: .rounded))
            if let entry = model.nowPlaying.entry, !entry.singers.isEmpty {
                Text(entry.singers.map(\.name).joined(separator: " & ")).font(.system(size: 54 * scale, weight: .heavy)).opacity(0.85)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
