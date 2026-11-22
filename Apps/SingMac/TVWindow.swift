import AppKit
import SingCore
import SingDesign
import SingHost
import SwiftUI

/// The TV is a borderless full-screen window on the chosen display, or a normal window when only one screen exists.
@MainActor
@Observable
/// A borderless TV window that still takes the keyboard, so Escape and Command-W always work.
final class TVPanel: NSWindow {
    var onEscape: (() -> Void)?
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        if cmd, event.charactersIgnoringModifiers == "w" { (onClose ?? onEscape)?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class TVWindowController {
    private var window: NSWindow?
    private(set) var isVisible = false
    private var observers: [NSObjectProtocol] = []

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

    func show(host: HostController, artwork: ArtworkCache, theme: @escaping () -> SingTheme, windowed: Bool = false) {
        hide()
        let controls = TVControls(
            windowed: { [weak self] in self?.showWindowed(host: host, artwork: artwork, theme: theme) },
            hide: { [weak self] in self?.hide() },
            quit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingView(rootView: TVRootView(host: host, artwork: artwork, theme: theme, controls: controls))
        let w: NSWindow
        let screen = windowed ? nil : targetScreen
        // A second screen gets a borderless window over it. With a single screen (a Mac mini on the TV), the TV uses
        // the system's full screen instead, in its own space, so the Sing! window and the menu bar stay reachable.
        if let screen, NSScreen.screens.count > 1, screen != NSScreen.main {
            let panel = TVPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            panel.setFrame(screen.frame, display: true)
            panel.level = .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.onEscape = { [weak self] in self?.hide() }
            w = panel
        } else {
            let panel = TVPanel(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "Sing! TV"
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.collectionBehavior = [.fullScreenPrimary]
            panel.setFrameAutosaveName("SingTVWindow")
            panel.onClose = { [weak self] in self?.hide() }
            panel.onEscape = { [weak panel] in
                guard let panel else { return }
                if panel.styleMask.contains(.fullScreen) { panel.toggleFullScreen(nil) } else { panel.miniaturize(nil) }
            }
            if let screen { panel.setFrame(screen.visibleFrame, display: false) } else { panel.center() }
            w = panel
        }
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = hosting
        w.makeKeyAndOrderFront(nil)
        window = w
        isVisible = true
        if screen != nil, !(NSScreen.screens.count > 1 && screen != NSScreen.main) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak w] in
                if let w, !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isVisible = false
                UserDefaults.standard.set(false, forKey: "tvVisible")
            }
        })
    }

    /// Leaves full screen and shows the TV as an ordinary window on the Mac's own screen.
    func showWindowed(host: HostController, artwork: ArtworkCache, theme: @escaping () -> SingTheme) {
        if let w = window, w.styleMask.contains(.fullScreen) {
            w.toggleFullScreen(nil)
            return
        }
        show(host: host, artwork: artwork, theme: theme, windowed: true)
    }

    func hide() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let w = window, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        window?.orderOut(nil)
        window = nil
        isVisible = false
        UserDefaults.standard.set(false, forKey: "tvVisible")
        NSApp.windows.first { $0.title == "Sing!" }?.makeKeyAndOrderFront(nil)
    }
}

/// Ways out of the TV window, shown when the mouse moves over it.
struct TVControls {
    var windowed: () -> Void
    var hide: () -> Void
    var quit: () -> Void
}

struct TVRootView: View {
    var host: HostController
    var artwork: ArtworkCache
    var theme: () -> SingTheme
    var controls: TVControls
    @State private var showControls = false
    @State private var lastMove = Date.distantPast

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
            .overlay(alignment: .topTrailing) {
                if showControls {
                    HStack(spacing: 10) {
                        Button { controls.windowed() } label: { Label("Show in a window", systemImage: "arrow.down.right.and.arrow.up.left") }
                        Button { controls.hide() } label: { Label("Hide the TV", systemImage: "eye.slash") }
                        Button(role: .destructive) { controls.quit() } label: { Label("Quit Sing!", systemImage: "power") }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .padding(24)
                    .transition(.opacity)
                }
            }
            .onContinuousHover { phase in
                if case .active = phase {
                    lastMove = .now
                    withAnimation(.easeOut(duration: 0.2)) { showControls = true }
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if showControls, Date.now.timeIntervalSince(lastMove) > 3 {
                        withAnimation(.easeIn(duration: 0.4)) { showControls = false }
                    }
                }
            }
    }
}
