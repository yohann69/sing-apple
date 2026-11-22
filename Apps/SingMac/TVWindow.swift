import AppKit
import SingCore
import SingDesign
import SingHost
import SwiftUI

/// The TV is a borderless full-screen window on the chosen display, or a normal window when only one screen exists.
@MainActor
@Observable
final class TVWindowController {
    private var window: NSWindow?
    private(set) var isVisible = false

    static var screens: [NSScreen] { NSScreen.screens }

    var preferredScreenName: String? {
        get { UserDefaults.standard.string(forKey: "tvScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "tvScreen") }
    }

    private var targetScreen: NSScreen? {
        let screens = NSScreen.screens
        if let name = preferredScreenName, let s = screens.first(where: { $0.localizedName == name }) { return s }
        return screens.count > 1 ? screens.first { $0 != NSScreen.main } : nil
    }

    func show(host: HostController, artwork: ArtworkCache, theme: @escaping () -> SingTheme) {
        hide()
        let root = TVRootView(host: host, artwork: artwork, theme: theme)
        let hosting = NSHostingView(rootView: root)
        let w: NSWindow
        if let screen = targetScreen {
            w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            w.setFrame(screen.frame, display: true)
            w.level = .mainMenu + 1
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.hidesOnDeactivate = false
        } else {
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Sing! TV"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.contentAspectRatio = NSSize(width: 16, height: 9)
            w.setFrameAutosaveName("SingTVWindow")
            w.center()
        }
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = hosting
        w.makeKeyAndOrderFront(nil)
        window = w
        isVisible = true
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = false }
        }
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        isVisible = false
    }
}

struct TVRootView: View {
    var host: HostController
    var artwork: ArtworkCache
    var theme: () -> SingTheme

    func makeModel() -> TVStageModel {
        let np = host.nowPlaying
        var model = TVStageModel(
            nowPlaying: np,
            lyrics: host.tvTranslation ?? host.lyrics,
            upNext: host.queue.entries.first,
            settings: host.settings.tv,
            artwork: artwork.image(np.entry?.song.id, host: host),
            joinURL: host.joinURL,
            guestCode: host.guestCode,
            preparingProgress: np.entry.flatMap { host.preparing[$0.song.id] },
            countdownEnd: host.countdownEnd,
            duration: host.duration,
            queuePreview: host.queue.entries
        )
        model.pitch = host.displayPitch
        model.result = host.nowPlaying.state == .finished ? host.lastResult : nil
        model.leaderboard = host.tonightBoard
        model.recap = host.recap
        model.funFacts = host.funFacts
        model.hostCode = host.hostCode
        model.videoURL = host.tvVideoURL
        model.meters = { [host] in host.nowPlaying.state == .playing ? host.micLevels : [] }
        model.live = { [host] in (host.livePoints, host.liveScore) }
        return model
    }

    var body: some View {
        let np = host.nowPlaying
        let model = makeModel()
        TVStageView(model: model) { host.lyricTime }
            .environment(\.singTheme, theme())
            .animation(.easeInOut(duration: 0.8), value: np.state)
            .animation(.easeInOut(duration: 0.8), value: np.entry?.id)
    }
}
