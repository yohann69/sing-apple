import AppKit
import SingCore
import SingDesign
import SingHost
import SwiftUI

@main
struct SingMacApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("Sing!", id: "main") {
            RootView()
                .environment(app)
                .environment(\.singTheme, app.theme)
                .frame(minWidth: 1100, minHeight: 700)
                .task { await app.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Playback") {
                Button("Play or Pause") { app.host?.togglePause() }.keyboardShortcut(.space, modifiers: [])
                Button("Next Song") { Task { await app.host?.playNext() } }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Restart Song") { app.host?.restart() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button(app.tv.isVisible ? "Hide TV Window" : "Show TV Window") { app.toggleTV() }.keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var host: HostController?
    var startupError: String?
    let tv = TVWindowController()
    let artwork = ArtworkCache()

    var theme: SingTheme { SingTheme(id: host?.settings.theme.preset) }

    func start() async {
        guard host == nil else { return }
        do {
            let h = try HostController()
            host = h
            await h.start()
            if UserDefaults.standard.bool(forKey: "tvVisible") || NSScreen.screens.count > 1 { showTV() }
            if h.songs.isEmpty, let samples = ProcessInfo.processInfo.environment["SING_SAMPLES"] {
                await h.importFiles([URL(fileURLWithPath: samples)])
            }
        } catch {
            startupError = error.localizedDescription
        }
    }

    func showTV() {
        guard let host else { return }
        tv.show(host: host, artwork: artwork, theme: { [weak self] in self?.theme ?? .ember })
        UserDefaults.standard.set(true, forKey: "tvVisible")
    }

    func toggleTV() {
        if tv.isVisible {
            tv.hide()
            UserDefaults.standard.set(false, forKey: "tvVisible")
        } else {
            showTV()
        }
    }
}

@MainActor
final class ArtworkCache {
    private var images: [SongID: NSImage] = [:]

    func image(_ id: SongID?, host: HostController?) -> Image? {
        guard let id, let host else { return nil }
        if let i = images[id] { return Image(nsImage: i) }
        guard let url = host.artworkFiles[id], let img = NSImage(contentsOf: url) else { return nil }
        images[id] = img
        return Image(nsImage: img)
    }
}
