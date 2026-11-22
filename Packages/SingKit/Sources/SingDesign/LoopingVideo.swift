import AVFoundation
import SwiftUI

/// A muted video looping forever behind the lyrics.
struct LoopingVideo: View {
    var url: URL
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        PlayerLayerView(player: player)
            .onAppear {
                let p = AVQueuePlayer()
                p.isMuted = true
                looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
    }
}

#if os(macOS)
struct PlayerLayerView: NSViewRepresentable {
    var player: AVPlayer?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let l = AVPlayerLayer()
        l.videoGravity = .resizeAspectFill
        v.layer = l
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { (v.layer as? AVPlayerLayer)?.player = player }
}
#else
struct PlayerLayerView: UIViewRepresentable {
    var player: AVPlayer?
    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }
    func makeUIView(context: Context) -> V {
        let v = V()
        (v.layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: V, context: Context) { (v.layer as? AVPlayerLayer)?.player = player }
}
#endif
