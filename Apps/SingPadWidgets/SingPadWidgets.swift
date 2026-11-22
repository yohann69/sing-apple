import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SingPadWidgets: WidgetBundle {
    var body: some Widget { TurnLiveActivity() }
}

struct TurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnAttributes.self) { ctx in
            HStack(spacing: 14) {
                Image(systemName: "music.mic").font(.title).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.headline(ctx.state.songsAway)).font(.headline)
                    Text("\(ctx.state.songTitle) · \(ctx.state.artist)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let now = ctx.state.nowPlaying { Text("Now: \(now)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "music.mic").foregroundStyle(.orange) }
                DynamicIslandExpandedRegion(.trailing) { Text(ctx.state.songsAway == 0 ? "Now" : "\(ctx.state.songsAway)").font(.title2.bold()) }
                DynamicIslandExpandedRegion(.bottom) { Text("\(Self.headline(ctx.state.songsAway)): \(ctx.state.songTitle)").lineLimit(1) }
            } compactLeading: {
                Image(systemName: "music.mic").foregroundStyle(.orange)
            } compactTrailing: {
                Text(ctx.state.songsAway == 0 ? "Now" : "\(ctx.state.songsAway)")
            } minimal: {
                Text(ctx.state.songsAway == 0 ? "🎤" : "\(ctx.state.songsAway)")
            }
        }
    }

    static func headline(_ away: Int) -> String {
        switch away {
        case 0: "Your turn!"
        case 1: "You're up next"
        default: "You're up in \(away) songs"
        }
    }
}
