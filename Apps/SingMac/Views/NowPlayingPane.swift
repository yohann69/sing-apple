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
            BlobBackground(colors: (np.entry?.song.paletteColors ?? theme.blobs).vivid(with: theme), base: theme.background, period: 40, dim: 0.45, still: np.state != .playing || !(NSApp.isActive))
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
        TimelineView(.animation(minimumInterval: 1 / 30, paused: host.nowPlaying.state != .playing)) { _ in
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
        TimelineView(.animation(minimumInterval: 0.25, paused: host.nowPlaying.state != .playing)) { _ in
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
            HStack {
                Stepper("Key: \(host.nowPlaying.keyShift > 0 ? "+" : "")\(host.nowPlaying.keyShift)", value: Binding(get: { host.nowPlaying.keyShift }, set: { host.setKey($0) }), in: -6...6)
                Spacer()
                Stepper("Tempo: \(Int((host.nowPlaying.tempo * 100).rounded()))%", value: Binding(get: { host.nowPlaying.tempo }, set: { host.setTempo($0) }), in: 0.75...1.25, step: 0.05)
            }
            .font(.callout)
            HStack {
                if host.nowPlaying.loopStartMs != nil {
                    Button("Stop practice loop") { host.setLoop(start: nil, end: nil) }
                } else {
                    Button("Practice: loop this line") {
                        if let l = host.lyrics, let i = l.lineIndex(at: host.lyricTime) ?? l.lines.firstIndex(where: { $0.start > host.lyricTime }) {
                            host.setLoop(start: Int(max(0, l.lines[i].start - 1) * 1000), end: Int((l.lines[i].end + 0.6) * 1000))
                        }
                    }
                }
            }
            .buttonStyle(.glass)
            Divider().opacity(0.3)
            HStack {
                Toggle("Microphone", isOn: $host.settings.playback.micEnabled)
                Spacer()
                MicMeter(level: { host.micLevel }, active: host.micRunning)
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
            Picker("Effect", selection: $host.settings.playback.micPreset) {
                ForEach(MicPreset.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
            }
            LabeledSlider(title: "Reverb", value: $host.settings.playback.micReverb, format: { "\(Int($0 * 100))%" })
            LabeledSlider(title: "Echo", value: $host.settings.playback.micEcho, format: { "\(Int($0 * 100))%" })
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

/// Mic level bars drawn with plain layers: updating them never re-lays out the SwiftUI window.
struct MicMeter: NSViewRepresentable {
    var level: () -> Float
    var active: Bool

    func makeNSView(context: Context) -> MeterView { MeterView() }
    func updateNSView(_ view: MeterView, context: Context) {
        view.level = level
        view.active = active
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeterView, context: Context) -> CGSize? {
        CGSize(width: 12 * 4 + 11 * 2, height: 14)
    }

    final class MeterView: NSView {
        var level: () -> Float = { 0 }
        var active = false { didSet { if active != oldValue { updateTimer() } } }
        private var bars: [CALayer] = []
        private var lit = -1
        private var timer: Timer?

        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 70, height: 14))
            wantsLayer = true
            for i in 0..<12 {
                let b = CALayer()
                b.cornerRadius = 1.5
                b.backgroundColor = (i > 9 ? NSColor.systemRed : (i > 7 ? NSColor.systemYellow : NSColor.systemGreen)).cgColor
                b.frame = CGRect(x: CGFloat(i) * 6, y: 0, width: 4, height: 14)
                b.opacity = 0.18
                b.actions = ["opacity": NSNull()]
                layer?.addSublayer(b)
                bars.append(b)
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTimer() }

        private func updateTimer() {
            let run = active && window != nil
            if run, timer == nil {
                let t = Timer(timeInterval: 1 / 15, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.step() }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            } else if !run {
                timer?.invalidate()
                timer = nil
                show(0)
            }
        }

        private func step() {
            guard window?.occlusionState.contains(.visible) == true else { return }
            show(Int((min(1, level() * 1.6) * 12).rounded(.up)))
        }

        private func show(_ n: Int) {
            guard n != lit else { return }
            lit = n
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, b) in bars.enumerated() { b.opacity = i < n ? 1 : 0.18 }
            CATransaction.commit()
        }
    }
}
