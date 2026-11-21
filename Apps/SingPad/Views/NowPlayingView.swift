import SingClient
import SingCore
import SingDesign
import SwiftUI

struct NowPlayingView: View {
    @Environment(PadModel.self) private var model
    @Environment(\.singTheme) private var theme
    @Environment(\.horizontalSizeClass) private var size

    var body: some View {
        let np = model.state.nowPlaying
        ZStack {
            BlobBackground(colors: (np.entry?.song.paletteColors ?? theme.blobs).vivid(with: theme), base: theme.background, period: 34, dim: 0.4)
            ScrollView {
                VStack(spacing: 26) {
                    if case .lost(let reason) = model.connection {
                        Label("Reconnecting… \(reason)", systemImage: "wifi.exclamationmark")
                            .font(.callout)
                            .padding(12)
                            .glassEffect(.regular.tint(.orange.opacity(0.3)), in: .capsule)
                    }
                    let layout = size == .regular ? AnyLayout(HStackLayout(alignment: .center, spacing: 36)) : AnyLayout(VStackLayout(spacing: 22))
                    layout {
                        ArtworkView(songID: np.entry?.song.id, palette: np.entry?.song.paletteColors ?? theme.blobs)
                            .frame(width: size == .regular ? 300 : 240, height: size == .regular ? 300 : 240)
                            .clipShape(RoundedRectangle(cornerRadius: 30))
                            .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
                            .id(np.entry?.song.id)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        VStack(alignment: size == .regular ? .leading : .center, spacing: 10) {
                            Text(label(np.state)).font(.caption.weight(.bold)).textCase(.uppercase).opacity(0.75)
                            Text(np.entry?.song.title ?? "Nothing playing").font(.system(size: 34, weight: .heavy)).multilineTextAlignment(size == .regular ? .leading : .center)
                            Text(np.entry?.song.artist ?? "Search for a song and queue it").font(.title3).opacity(0.75)
                            HStack { ForEach(np.entry?.singers ?? []) { SingerChip($0) } }
                            if np.state == .preparing, let id = np.entry?.song.id {
                                ProgressView(value: model.state.preparing[id] ?? 0) { Text("Preparing the instrumental…").font(.caption) }
                                    .tint(.white)
                                    .frame(maxWidth: 280)
                            }
                        }
                    }
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: np.entry?.id)

                    if np.entry != nil {
                        LyricsCard()
                        ProgressBar()
                    }
                    if model.isHost { HostControls() }
                    UpNextCard()
                }
                .padding(24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func label(_ s: PlaybackState) -> String {
        switch s {
        case .idle: "Waiting for a song"
        case .preparing: "Preparing"
        case .countdown: "Get ready"
        case .playing: "Now singing"
        case .paused: "Paused"
        case .finished: "Bravo!"
        }
    }
}

struct LyricsCard: View {
    @Environment(PadModel.self) private var model
    @Environment(\.singTheme) private var theme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let t = model.position
            VStack(alignment: .leading, spacing: 10) {
                if let lyrics = model.lyrics, lyrics.kind != .plain {
                    let i = lyrics.lineIndex(at: t + 0.15) ?? -1
                    if i >= 0 {
                        KaraokeLineView(segments: lyrics.lines[i].segments, time: t, font: theme.lyricFont(size: 26), wordSpacing: 7, wipe: lyrics.kind >= .word || model.state.settings.tv.estimatedWordWipe)
                            .id(i)
                            .transition(.push(from: .bottom))
                    } else {
                        Text("♪").font(theme.lyricFont(size: 26)).opacity(0.6)
                    }
                    if i >= 0, let tr = lyrics.lines[i].translation {
                        Text(tr).font(.system(size: 18, weight: .semibold)).italic().opacity(0.75)
                    }
                    if lyrics.lines.indices.contains(i + 1) {
                        Text(lyrics.lines[i + 1].text).font(theme.lyricFont(size: 18)).opacity(0.5)
                    }
                } else {
                    Text(model.state.nowPlaying.currentLine ?? "Lyrics show here while you sing").font(theme.lyricFont(size: 22)).opacity(0.8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .padding(20)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
        }
    }
}

struct ProgressBar: View {
    @Environment(PadModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let pos = model.position
            let dur = Double(model.state.nowPlaying.entry?.song.durationMs ?? 1) / 1000
            VStack(spacing: 6) {
                ProgressView(value: min(pos, dur), total: max(dur, 1)).tint(.white)
                HStack {
                    Text(fmt(pos))
                    Spacer()
                    Text("-" + fmt(dur - pos))
                }
                .font(.caption.monospacedDigit()).opacity(0.75)
            }
        }
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct HostControls: View {
    @Environment(PadModel.self) private var model
    @State private var guide: Double = 0
    @State private var editing = false

    var body: some View {
        let np = model.state.nowPlaying
        VStack(spacing: 20) {
            GlassEffectContainer(spacing: 24) {
                HStack(spacing: 24) {
                    control("backward.end.fill", "Restart") { model.send(.transport(.restart)) }
                    Button { model.send(.transport(.pause)) } label: {
                        Image(systemName: np.state == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 34, weight: .bold))
                            .frame(width: 84, height: 84)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.white.opacity(0.15)).interactive(), in: .circle)
                    .accessibilityLabel(np.state == .playing ? "Pause" : "Play")
                    control("forward.end.fill", "Next song") { model.send(.transport(.skip)) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Guide vocal", systemImage: "person.wave.2")
                    Spacer()
                    Text("\(Int(guide * 100))%").monospacedDigit().opacity(0.75)
                }
                Slider(value: $guide, in: 0...1) { e in
                    editing = e
                    if !e { model.send(.setGuideVocal(guide)) }
                }
                .tint(.white)
            }
            .padding(18)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        }
        .onAppear { guide = np.guideVocal }
        .onChange(of: np.guideVocal) { _, v in if !editing { guide = v } }
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

struct UpNextCard: View {
    @Environment(PadModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up next").font(.headline)
            if model.state.queue.isEmpty { Text("Nobody is queued. Be the first!").opacity(0.7) }
            ForEach(model.state.queue.prefix(4)) { e in
                HStack(spacing: 12) {
                    ArtworkView(songID: e.song.id, palette: e.song.paletteColors)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading) {
                        Text(e.song.title).fontWeight(.semibold).lineLimit(1)
                        Text(e.singers.map(\.name).joined(separator: " & ").isEmpty ? e.song.artist : e.singers.map(\.name).joined(separator: " & ")).font(.caption).opacity(0.75)
                    }
                    Spacer()
                    if let t = e.estimatedStart { Text(t, style: .time).font(.caption.monospacedDigit()).opacity(0.75) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
    }
}
