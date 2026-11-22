import AVFoundation
import SingCore
import SingDesign
import SingHost
import SwiftUI

struct SongSettingsSheet: View {
    var host: HostController
    var song: SongSummary
    @Environment(\.dismiss) private var dismiss
    @State private var settings: SongSettings?

    var body: some View {
        NavigationStack {
            Form {
                if settings != nil {
                    SongSettingsForm(settings: Binding(get: { settings ?? SongSettings() }, set: { settings = $0 }))
                } else {
                    ProgressView()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(song.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let settings else { return }
                        Task { await host.updateSongSettings(song.id, settings); dismiss() }
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .task { settings = await host.songSettings(song.id) }
    }
}

/// Fix lyric timing by ear: play the song, then nudge lines or tap them in as they are sung.
struct SyncEditorView: View {
    var host: HostController
    var song: SongSummary
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics: Lyrics?
    @State private var player: AVPlayer?
    @State private var now: Double = 0
    @State private var playing = false
    @State private var selected: Int?
    @State private var reaction = 0.15
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 26) }
                    .keyboardShortcut("p", modifiers: [])
                Button { seek(now - 5) } label: { Image(systemName: "gobackward.5") }
                Button { seek(now + 5) } label: { Image(systemName: "goforward.5") }
                Text(Self.time(now)).monospacedDigit().frame(width: 80, alignment: .leading)
                Slider(value: Binding(get: { now }, set: { seek($0) }), in: 0...max(1, Double(song.durationMs) / 1000))
                Divider().frame(height: 20)
                Button("Shift all −0.1 s") { shiftAll(-0.1) }
                Button("+0.1 s") { shiftAll(0.1) }
            }
            .padding(14)
            Text("Select a line and press Space as it starts to set it, then the next line is selected. Or nudge a line with the arrows.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            ScrollViewReader { proxy in
                List(selection: $selected) {
                    if let lyrics {
                        ForEach(lyrics.lines.indices, id: \.self) { i in
                            let line = lyrics.lines[i]
                            HStack(spacing: 12) {
                                Text(Self.time(line.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                                Text(line.text).fontWeight(isCurrent(i) ? .bold : .regular).foregroundStyle(isCurrent(i) ? Color.orange : .primary)
                                Spacer()
                                Button { nudge(i, -0.1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                                Button { nudge(i, 0.1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                                Button("Set here") { setLine(i, at: now) }.buttonStyle(.borderless)
                                Button { seek(max(0, line.start - 1.5)); if !playing { toggle() } } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
                            }
                            .tag(i)
                            .id(i)
                        }
                    }
                }
                .onChange(of: selected) { _, v in if let v { withAnimation { proxy.scrollTo(v, anchor: .center) } } }
            }
            .focusable()
            .focused($focused)
            .onKeyPress(.space) {
                guard let i = selected, let l = lyrics, l.lines.indices.contains(i) else { return .ignored }
                setLine(i, at: now - reaction)
                selected = l.lines.indices.contains(i + 1) ? i + 1 : nil
                return .handled
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .navigationTitle("Lyric timing: \(song.title)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { player?.pause(); dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let lyrics else { return }
                    saving = true
                    player?.pause()
                    Task {
                        try? await host.saveSyncedLyrics(song.id, lyrics)
                        dismiss()
                    }
                }
                .disabled(lyrics == nil || saving)
            }
        }
        .task {
            let settings = await host.songSettings(song.id)
            lyrics = await host.rawLyrics(song.id).map { $0.shifted(by: Double(settings?.lyricOffsetMs ?? 0) / 1000) }
            if let url = await host.songFileURL(song.id) { player = AVPlayer(url: url) }
            focused = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if let p = player { now = p.currentTime().seconds.isFinite ? p.currentTime().seconds : now }
            }
        }
        .onDisappear { player?.pause() }
    }

    private func isCurrent(_ i: Int) -> Bool { lyrics?.lineIndex(at: now) == i }

    static func time(_ t: Double) -> String {
        let v = max(0, t)
        return String(format: "%d:%05.2f", Int(v) / 60, v.truncatingRemainder(dividingBy: 60))
    }

    private func toggle() {
        guard let player else { return }
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }

    private func seek(_ t: Double) {
        let v = max(0, min(t, Double(song.durationMs) / 1000))
        player?.seek(to: CMTime(seconds: v, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        now = v
    }

    private func nudge(_ i: Int, _ d: Double) {
        guard let l = lyrics else { return }
        setLine(i, at: l.lines[i].start + d)
    }

    /// Moves a line with all its words, keeping it before the next line.
    private func setLine(_ i: Int, at t: Double) {
        guard var l = lyrics, l.lines.indices.contains(i) else { return }
        let delta = max(0, t) - l.lines[i].start
        var line = l.lines[i]
        line.start += delta
        line.end += delta
        line.segments = line.segments.map { var s = $0; s.start += delta; s.end += delta; return s }
        line.background = line.background.map { var s = $0; s.start += delta; s.end += delta; return s }
        l.lines[i] = line
        if i > 0, l.lines[i - 1].end > line.start { l.lines[i - 1].end = line.start }
        if l.kind < .line { l.kind = .line }
        lyrics = l
    }

    private func shiftAll(_ d: Double) { lyrics = lyrics?.shifted(by: d) }
}
