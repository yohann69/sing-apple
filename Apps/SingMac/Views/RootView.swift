import SingCore
import SingDesign
import SingHost
import SwiftUI
import Translation

enum Pane: String, CaseIterable, Identifiable {
    case nowPlaying, queue, library, singers, stats, pads, storage, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .queue: "Queue"
        case .library: "Library"
        case .singers: "Singers"
        case .stats: "Stats"
        case .pads: "Pads"
        case .storage: "Storage"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: "music.mic"
        case .queue: "list.number"
        case .library: "music.note.list"
        case .singers: "person.2.fill"
        case .stats: "chart.bar.xaxis"
        case .pads: "ipad.and.iphone"
        case .storage: "internaldrive"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var pane: Pane? = .nowPlaying

    var body: some View {
        if let host = app.host {
            NavigationSplitView {
                List(selection: $pane) {
                    Section {
                        ForEach([Pane.nowPlaying, .queue, .library]) { p in row(p, host: host) }
                    }
                    Section("Party") {
                        ForEach([Pane.singers, .stats, .pads]) { p in row(p, host: host) }
                    }
                    Section {
                        row(.settings, host: host)
                    }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
                .safeAreaInset(edge: .bottom) { SidebarFooter(host: host, app: app).padding(10) }
            } detail: {
                Group {
                    switch pane ?? .nowPlaying {
                    case .nowPlaying: NowPlayingPane(host: host)
                    case .queue: QueuePane(host: host)
                    case .library: LibraryPane(host: host)
                    case .singers: SingersPane(host: host)
                    case .stats: StatsPane(host: host)
                    case .pads: PadsPane(host: host)
                    case .storage: StoragePane(host: host)
                    case .settings: SettingsPane(host: host)
                    }
                }
                .toolbar { TransportToolbar(host: host) }
            }
            .translationTask(host.pendingTranslationDownload.map { TranslationSession.Configuration(source: .init(identifier: $0.source), target: .init(identifier: $0.target)) }) { session in
                nonisolated(unsafe) let s = session
                try? await s.prepareTranslation()
                host.translationDownloadFinished()
            }
            .overlay(alignment: .bottom) {
                if let error = host.lastError {
                    Text(error)
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular.tint(.orange.opacity(0.3)), in: .capsule)
                        .padding(20)
                        .onTapGesture { host.clearError() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        } else if let error = app.startupError {
            ContentUnavailableView("Sing! could not start", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView("Starting Sing!…")
        }
    }

    @ViewBuilder private func row(_ p: Pane, host: HostController) -> some View {
        Label(p.title, systemImage: p.symbol)
            .badge(p == .queue ? host.queue.entries.count : (p == .pads ? host.connectedPads.count : 0))
            .tag(p)
    }
}

struct SidebarFooter: View {
    var host: HostController
    var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(host.serverRunning ? .green : .red).frame(width: 8, height: 8)
                Text(host.serverRunning ? "Pads can connect" : "Pad server off").font(.caption)
                Spacer()
            }
            Button {
                app.toggleTV()
            } label: {
                Label(app.tv.isVisible ? "Hide TV" : "Show TV", systemImage: "tv")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }
}

struct TransportToolbar: ToolbarContent {
    var host: HostController

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Button { host.restart() } label: { Image(systemName: "backward.end.fill") }
                .help("Restart the song")
            Button { host.togglePause() } label: {
                Image(systemName: host.nowPlaying.state == .playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help("Play or pause")
            Button { Task { await host.playNext() } } label: { Image(systemName: "forward.end.fill") }
                .help("Next song")
        }
        ToolbarItem(placement: .principal) {
            NowPlayingTicker(host: host)
        }
    }
}

struct NowPlayingTicker: View {
    var host: HostController

    var body: some View {
        HStack(spacing: 10) {
            if let e = host.nowPlaying.entry {
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.song.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(e.singers.map(\.name).joined(separator: " & ").nilIfEmpty ?? e.song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Nothing playing").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 200, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
