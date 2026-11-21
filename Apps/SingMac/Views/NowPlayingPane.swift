import AppKit
import SingCore
import SingDesign
import SingHost
import SwiftUI

struct NowPlayingPane: View {
    var host: HostController
    @Environment(AppModel.self) private var app
    @Environment(\.singTheme) private var theme

    var body: some View {
        let np = host.nowPlaying
        ZStack {
            BlobBackground(colors: (np.entry?.song.paletteColors ?? theme.blobs).vivid(with: theme), base: theme.background, period: 40, dim: 0.45)
            ScrollView {
                VStack(spacing: 28) {
                    header(np)
                    if np.entry != nil {
                        lyricsPreview
                        progress
                    }
                    GlassEffectContainer(spacing: 20) {
                        HStack(alignment: .top, spacing: 20) {
                            mixer
                            upNext
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .navigationTitle("Now Playing")
    }

    @ViewBuilder private func header(_ np: NowPlaying) -> some View {
        HStack(spacing: 28) {
            Group {
                if let img = app.artwork.image(np.entry?.song.id, host: host) {
                    img.resizable().scaledToFill()
                } else {
                    ArtworkPlaceholder(palette: np.entry?.song.paletteColors ?? theme.blobs, symbol: "music.mic")
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .id(np.entry?.song.id)
            .transition(.scale(scale: 0.9).combined(with: .opacity))

            VStack(alignment: .leading, spacing: 10) {
                Text(stateLabel(np)).font(.caption.weight(.bold)).textCase(.uppercase).opacity(0.7)
                Text(np.entry?.song.title ?? "Nothing playing").font(.system(size: 40, weight: .heavy)).lineLimit(2)
                Text(np.entry?.song.artist ?? "Queue a song from the library or from a pad.").font(.title3).opacity(0.75)
                HStack {
                    ForEach(np.entry?.singers ?? []) { SingerChip($0) }
                }
                if np.state == .preparing, let id = np.entry?.song.id {
                    ProgressView(value: host.preparing[id] ?? 0) { Text("Separating vocals…").font(.caption) }
                        .tint(.white)
                        .frame(maxWidth: 320)
                }
            }
            Spacer()
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: np.entry?.id)
    }

    private func stateLabel(_ np: NowPlaying) -> String {
        switch np.state {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .countdown: "Get ready"
        case .playing: "Now singing"
        case .paused: "Paused"
        case .finished: "Finished"
        }
    }

    private var lyricsPreview: some View {
        TimelineView(.animation) { _ in
            let t = host.lyricTime
            VStack(alignment: .leading, spacing: 12) {
                if let lyrics = host.lyrics {
                    let i = lyrics.lineIndex(at: t + 0.15) ?? -1
                    if i >= 0 {
                        KaraokeLineView(segments: lyrics.lines[i].segments, time: t, font: theme.lyricFont(size: 30), wordSpacing: 8, wipe: lyrics.kind >= .word || host.settings.tv.estimatedWordWipe)
                            .id(i)
                    }
                    if lyrics.lines.indices.contains(i + 1) {
                        Text(lyrics.lines[i + 1].text).font(theme.lyricFont(size: 20)).opacity(0.5)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "text.quote")
                        Text("\(lyrics.kind.rawValue.capitalized) synced · \(lyrics.source.rawValue)")
                    }
                    .font(.caption).opacity(0.6)
                } else {
                    Text("No lyrics found for this song").opacity(0.6)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            .padding(20)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let pos = max(0, host.lyricTime - host.lyricOffset)
            let dur = max(host.duration, 1)
            VStack(spacing: 6) {
                Slider(value: Binding(get: { pos }, set: { host.seek(to: $0) }), in: 0...dur)
                    .tint(.white)
                HStack {
                    Text(format(pos))
                    Spacer()
                    Text("-" + format(dur - pos))
                }
                .font(.caption.monospacedDigit()).opacity(0.7)
            }
        }
    }

    private func format(_ t: Double) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var mixer: some View {
        @Bindable var host = host
        return VStack(alignment: .leading, spacing: 16) {
            Text("Mix").font(.headline)
            LabeledSlider(title: "Guide vocal", value: Binding(get: { host.nowPlaying.guideVocal }, set: { host.setGuideVocal($0) }), format: { "\(Int($0 * 100))%" })
            LabeledSlider(title: "Music volume", value: $host.settings.playback.musicVolume, format: { "\(Int($0 * 100))%" })
            Divider().opacity(0.3)
            HStack {
                Toggle("Microphone", isOn: $host.settings.playback.micEnabled)
                Spacer()
                MicMeter(level: host.micLevel)
            }
            if let msg = host.micStateText {
                VStack(alignment: .leading, spacing: 8) {
                    Label(msg, systemImage: "mic.slash.fill").font(.callout)
                    HStack {
                        Button("Reset microphone permission") { host.resetMicPermission() }
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                    .buttonStyle(.glass)
                }
                .padding(12)
                .glassEffect(.regular.tint(.orange.opacity(0.3)), in: RoundedRectangle(cornerRadius: 16))
            }
            LabeledSlider(title: "Mic volume", value: $host.settings.playback.micGain, format: { "\(Int($0 * 100))%" })
            LabeledSlider(title: "Reverb", value: $host.settings.playback.micReverb, format: { "\(Int($0 * 100))%" })
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up next").font(.headline)
            if host.queue.entries.isEmpty {
                Text("The queue is empty").opacity(0.6)
            }
            ForEach(host.queue.withEstimates(remainingCurrent: max(0, host.duration - host.lyricTime)).prefix(5)) { e in
                HStack(spacing: 10) {
                    if let s = e.singers.first { SingerChip(s, compact: true) }
                    VStack(alignment: .leading) {
                        Text(e.song.title).fontWeight(.semibold).lineLimit(1)
                        Text(e.song.artist).font(.caption).opacity(0.7).lineLimit(1)
                    }
                    Spacer()
                    if let t = e.estimatedStart { Text(t, style: .time).font(.caption.monospacedDigit()).opacity(0.7) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().opacity(0.7)
            }
            .font(.callout)
            Slider(value: $value, in: range)
        }
    }
}

struct MicMeter: View {
    var level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { _ in
            HStack(spacing: 2) {
                ForEach(0..<12) { i in
                    let lit = Float(i) / 12 < min(1, level * 1.6)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i > 9 ? Color.red : (i > 7 ? .yellow : .green))
                        .opacity(lit ? 1 : 0.18)
                        .frame(width: 4, height: 14)
                }
            }
        }
    }
}
