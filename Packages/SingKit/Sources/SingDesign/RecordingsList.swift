#if !os(tvOS)
import AVFoundation
import SingCore
import SwiftUI

/// Listen back to performances; hosts can also replay one on the TV, keep or delete it.
public struct RecordingsList: View {
    let recordings: [RecordingInfo]
    let audioURL: (RecordingInfo) -> URL
    let shareURL: (RecordingInfo) -> String
    let canManage: Bool
    let onKeep: (RecordingInfo) -> Void
    let onDelete: (RecordingInfo) -> Void
    let onReplay: (RecordingInfo) -> Void
    @State private var player: AVPlayer?
    @State private var playingID: Int64?
    @State private var sharing: RecordingInfo?

    public init(recordings: [RecordingInfo], audioURL: @escaping (RecordingInfo) -> URL, shareURL: @escaping (RecordingInfo) -> String, canManage: Bool,
                onKeep: @escaping (RecordingInfo) -> Void, onDelete: @escaping (RecordingInfo) -> Void, onReplay: @escaping (RecordingInfo) -> Void) {
        self.recordings = recordings
        self.audioURL = audioURL
        self.shareURL = shareURL
        self.canManage = canManage
        self.onKeep = onKeep
        self.onDelete = onDelete
        self.onReplay = onReplay
    }

    public var body: some View {
        Group {
            if recordings.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "waveform", description: Text("Turn on recording in the party settings and every performance is saved here."))
            }
            ForEach(recordings) { r in
                HStack(spacing: 14) {
                    Button { toggle(r) } label: {
                        Image(systemName: playingID == r.id ? "stop.fill" : "play.fill").font(.title3).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(playingID == r.id ? "Stop" : "Play \(r.songTitle)")
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(r.songTitle).fontWeight(.semibold).lineLimit(1)
                            if r.kept { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.orange) }
                        }
                        Text(([r.singers.map(\.name).joined(separator: " & "), r.recordedAt.formatted(date: .abbreviated, time: .shortened)] + (r.score.map { ["\($0) pts"] } ?? [])).filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button { sharing = r } label: { Label("Share with a QR code", systemImage: "qrcode") }
                        Button { onKeep(r) } label: { Label(r.kept ? "Let it expire" : "Keep forever", systemImage: r.kept ? "bookmark.slash" : "bookmark") }
                        if canManage {
                            Button { onReplay(r) } label: { Label("Replay on the TV", systemImage: "tv") }
                            Button(role: .destructive) { onDelete(r) } label: { Label("Delete", systemImage: "trash") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                    .accessibilityLabel("More")
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }
        }
        .sheet(item: $sharing) { r in
            VStack(spacing: 18) {
                Text(r.songTitle).font(.title2.bold())
                QRCodeView(shareURL(r)).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 18)).frame(width: 260, height: 260)
                Text("Scan with a phone on the same Wi-Fi to listen or download.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(shareURL(r)).font(.caption.monospaced()).textSelection(.enabled)
                Button("Done") { sharing = nil }.buttonStyle(.glassProminent)
            }
            .padding(30)
            .presentationDetents([.medium, .large])
        }
        .onDisappear { player?.pause(); player = nil; playingID = nil }
    }

    private func toggle(_ r: RecordingInfo) {
        if playingID == r.id {
            player?.pause()
            playingID = nil
            return
        }
        let p = AVPlayer(url: audioURL(r))
        player = p
        playingID = r.id
        p.play()
    }
}

#endif
