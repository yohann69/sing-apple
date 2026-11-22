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
    public var leaderboard: [RankedName] = []
    public var recap: PartyRecap?
    public var funFacts: [String] = []
    /// Only the Mac's own TV window knows it; other screens leave it empty.
    public var hostCode: String?
    public var videoURL: URL?
    public var meters: () -> [Float] = { [] }
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
                if model.settings.showHostCode, let code = model.hostCode {
                    Text("Host code \(code)")
                        .font(.system(size: 20 * scale, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 16 * scale).padding(.vertical, 8 * scale)
                        .glassEffect(.regular, in: .capsule)
                        .padding(30 * scale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .environment(\.tvScale, scale)
            .environment(\.singTheme, { var t = theme; t.fontStyle = model.settings.lyricFont == "default" ? nil : model.settings.lyricFont; return t }())
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
        case .video:
            ZStack {
                theme.background
                if let url = model.videoURL { LoopingVideo(url: url).opacity(0.75) }
                Color.black.opacity(0.3)
            }.ignoresSafeArea()
        }
    }

    @ViewBuilder private func content(scale: CGFloat) -> some View {
        switch model.nowPlaying.state {
        case .idle:
            if let recap = model.recap {
                RecapStage(recap: recap, scale: scale).transition(.blurFade)
            } else {
                IdleStage(model: model, scale: scale).transition(.blurFade)
            }
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
                    PitchGuideView(track: track, time: t, live: live.points, color: model.nowPlaying.entry?.singers.first?.color ?? theme.accent, score: live.score, showScore: model.settings.showLiveScore && !model.settings.justForFun, scale: scale)
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
            let levels = model.meters()
            if !levels.isEmpty { MicMeters(levels: levels, scale: scale) }
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
/// One line at a time, in place: the line being sung large in the middle, the previous and next lines
/// smaller above and below when those options are on. Lines change with a quick crossfade, never a scroll.
struct LyricsColumn: View {
    var lyrics: Lyrics
    var time: TimeInterval
    var settings: TVDisplaySettings
    var singers: [Singer]
    var scale: CGFloat
    @Environment(\.singTheme) private var theme

    /// Voices alternate sides: first on the left, second on the right, and so on.
    private func alignment(_ line: LyricLine, in l: Lyrics) -> HorizontalAlignment {
        guard let i = l.voiceIndex(of: line) else { return .leading }
        return i % 2 == 1 ? .trailing : .leading
    }

    private func voiceColor(_ line: LyricLine, in l: Lyrics) -> Color? {
        guard settings.showSingerNames else { return nil }
        return l.voiceIndex(of: line).map { Color(hex: VoicePalette.hex[$0 % VoicePalette.hex.count]) }
    }

    /// The line to show: the one being sung, or the next one during a short break.
    private func focusIndex(_ lines: [LyricLine]) -> Int {
        guard let i = Lyrics(kind: lyrics.kind, source: lyrics.source, lines: lines).lineIndex(at: time + 0.25) else { return 0 }
        if time > lines[i].end + 0.4, i + 1 < lines.count { return i + 1 }
        return i
    }

    var body: some View {
        GeometryReader { geo in
            let size = settings.lyricSize * scale
            // About how many characters fit on one row at this size; longer lines are cut into pieces.
            let maxChars = max(14, Int(geo.size.width / (size * 0.5)))
            let l = lyrics.splitForDisplay(maxChars: maxChars)
            let lines = l.lines
            let focus = focusIndex(lines)
            let focusLine = lines[focus]
            let waiting = time < focusLine.start - 0.2
            let pause = l.breakProgress(at: time)
            let showPrev = settings.showPreviousLine && focus > 0 && pause == nil
            let showNext = settings.showNextLine && focus + 1 < lines.count && pause == nil
            let small = size * 0.56

            VStack(spacing: size * 0.38) {
                Group {
                    if showPrev {
                        lineView(lines[focus - 1], in: l, state: .past, size: small)
                            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment(lines[focus - 1], in: l), vertical: .center))
                            .id("p\(focus - 1)")
                    } else {
                        Color.clear.frame(height: small * 1.2)
                    }
                }
                .transition(.opacity)

                ZStack {
                    if let p = pause {
                        if settings.showCountdown {
                            CountdownDots(progress: p, scale: scale)
                                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment(focusLine, in: l), vertical: .center))
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    } else {
                        lineView(focusLine, in: l, state: waiting ? .upcoming : .current, size: size)
                            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment(focusLine, in: l), vertical: .center))
                            .id("c\(focus)")
                            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity))
                    }
                }
                .frame(minHeight: size * 1.3)

                Group {
                    if showNext {
                        lineView(lines[focus + 1], in: l, state: .upcoming, size: small)
                            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment(lines[focus + 1], in: l), vertical: .center))
                            .id("n\(focus + 1)")
                    } else {
                        Color.clear.frame(height: small * 1.2)
                    }
                }
                .transition(.opacity)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .animation(.easeInOut(duration: 0.28), value: focus)
            .animation(.easeInOut(duration: 0.45), value: pause == nil)
            .animation(.easeInOut(duration: 0.35), value: waiting)
        }
    }

    enum LineState { case past, current, upcoming }

    private func lineView(_ line: LyricLine, in l: Lyrics, state: LineState, size: CGFloat) -> some View {
        let align = alignment(line, in: l)
        // One voice: white text. Several voices: each voice keeps its own color, sung or not.
        let voice = voiceColor(line, in: l)
        let isCurrent = state == .current
        let sung = voice ?? .white
        let dim = (voice ?? .white).opacity(isCurrent ? 0.4 : (state == .past ? 0.45 : 0.55))
        let wipe = (l.kind >= .word || settings.estimatedWordWipe) && isCurrent
        let t = state == .past ? max(time, line.end + 1) : (state == .upcoming ? min(time, line.start - 1) : time)
        return VStack(alignment: align, spacing: 10 * scale) {
            KaraokeLineView(segments: line.segments, time: t, font: theme.lyricFont(size: size), wordSpacing: size * 0.26,
                            sung: state == .past ? sung.opacity(0.55) : sung, dim: dim, glow: (voice ?? .white).mix(with: .white, by: 0.35), alignment: align, wipe: wipe)
            if isCurrent, settings.showBackingVocals, !line.background.isEmpty {
                KaraokeLineView(segments: line.background, time: t, font: theme.lyricFont(size: size * 0.42).italic(), wordSpacing: size * 0.1,
                                sung: sung.opacity(0.9), dim: (voice ?? .white).opacity(0.3), glow: voice ?? .white, alignment: align, wipe: wipe)
            }
            if isCurrent || state == .upcoming, settings.showRomanization, let ro = line.romanization {
                Text(ro).font(.system(size: size * 0.36, weight: .medium)).opacity(isCurrent ? 0.75 : 0.5)
            }
            if isCurrent, settings.showTranslation, let tr = line.translation {
                Text(tr).font(.system(size: size * 0.34, weight: .semibold)).opacity(0.6)
            }
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Three dots that breathe and fill one after another across a pause, like Apple Music.
struct CountdownDots: View {
    /// 0 at the start of the pause, 1 when singing resumes.
    var progress: Double
    var scale: CGFloat

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breathe = 1 + 0.08 * sin(t * 2 * .pi / 2.4)
            HStack(spacing: 26 * scale) {
                ForEach(0..<3) { i in
                    let fill = max(0, min(1, progress * 3 - Double(i)))
                    Circle()
                        .fill(.white.opacity(0.22 + 0.73 * fill))
                        .frame(width: 30 * scale, height: 30 * scale)
                        .scaleEffect((0.82 + 0.18 * fill) * breathe)
                        .shadow(color: .white.opacity(0.5 * fill), radius: 12 * scale * fill)
                }
            }
            .scaleEffect(progress > 0.97 ? 1 + (progress - 0.97) * 4 : 1)
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
                if model.settings.showLeaderboard, !model.settings.justForFun, !model.leaderboard.isEmpty {
                    LeaderboardPanel(board: model.leaderboard, scale: scale).padding(.top, 20 * scale)
                }
                if model.settings.showFunStats, !model.funFacts.isEmpty {
                    FunFacts(facts: model.funFacts, scale: scale).padding(.top, 16 * scale)
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
            .overlay(alignment: .bottomTrailing) {
                if model.settings.showLeaderboard, !model.settings.justForFun, !model.leaderboard.isEmpty {
                    LeaderboardPanel(board: Array(model.leaderboard.prefix(3)), scale: scale * 0.8).padding(40 * scale)
                }
            }
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

/// Tonight's best scores, shown between songs.
struct LeaderboardPanel: View {
    var board: [RankedName]
    var scale: CGFloat
    @Environment(\.singTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text("Tonight's top scores").font(.system(size: 26 * scale, weight: .bold)).opacity(0.85)
            ForEach(Array(board.prefix(5).enumerated()), id: \.element.id) { i, r in
                HStack(spacing: 14 * scale) {
                    Text(["🥇", "🥈", "🥉", "4", "5"][i]).frame(width: 40 * scale)
                    Circle().fill(r.colorHex.map { Color(hex: $0) } ?? theme.accent).frame(width: 14 * scale, height: 14 * scale)
                    Text(r.name).fontWeight(.semibold)
                    Spacer(minLength: 30 * scale)
                    Text("\(r.count)").font(.system(size: 28 * scale, weight: .black, design: .rounded)).monospacedDigit()
                }
                .font(.system(size: 26 * scale))
            }
        }
        .padding(28 * scale)
        .frame(width: 520 * scale)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32 * scale))
    }
}

/// The end-of-party summary.
struct RecapStage: View {
    var recap: PartyRecap
    var scale: CGFloat
    @Environment(\.singTheme) private var theme

    var body: some View {
        VStack(spacing: 40 * scale) {
            Text("What a night!")
                .font(.system(size: 120 * scale, weight: .black, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [theme.accentSoft, theme.accent], startPoint: .top, endPoint: .bottom))
            HStack(spacing: 30 * scale) {
                stat("\(recap.songs)", "songs")
                stat("\(recap.minutes)", "minutes")
                stat("\(recap.singers)", "singers")
                if let b = recap.bestScore { stat("\(b.count)", "best score") }
            }
            VStack(spacing: 14 * scale) {
                ForEach(recap.highlights, id: \.self) { h in
                    Text(h).font(.system(size: 34 * scale, weight: .semibold))
                }
            }
            if let reel = recap.reelURL {
                HStack(spacing: 20 * scale) {
                    QRCodeView(reel).padding(12 * scale).background(.white, in: RoundedRectangle(cornerRadius: 18 * scale)).frame(width: 170 * scale, height: 170 * scale)
                    Text("The night's highlights,\nscan to take them home").font(.system(size: 28 * scale, weight: .semibold))
                }
            }
            Text("Thanks for singing.").font(.system(size: 28 * scale)).opacity(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 6 * scale) {
            Text(value).font(.system(size: 80 * scale, weight: .black, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 26 * scale, weight: .semibold)).opacity(0.75)
        }
        .frame(width: 260 * scale, height: 200 * scale)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32 * scale))
    }
}

/// One fact about tonight at a time, gently cycling.
struct FunFacts: View {
    var facts: [String]
    var scale: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 6)) { ctx in
            let i = Int(ctx.date.timeIntervalSinceReferenceDate / 6) % max(1, facts.count)
            Label(facts[i], systemImage: "sparkles")
                .font(.system(size: 28 * scale, weight: .semibold))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.6), value: i)
        }
    }
}

/// Small level bars for each mic, shown while someone sings.
public struct MicMeters: View {
    var levels: [Float]
    var scale: CGFloat

    public init(levels: [Float], scale: CGFloat = 1) {
        self.levels = levels
        self.scale = scale
    }

    public var body: some View {
        HStack(spacing: 6 * scale) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                Capsule().fill(.white.opacity(0.18)).frame(width: 8 * scale, height: 36 * scale)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(l > 0.85 ? Color.red : .white).frame(width: 8 * scale, height: 36 * scale * CGFloat(min(1, max(0.04, l * 1.6))))
                    }
            }
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}
