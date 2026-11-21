import SwiftUI
import SingCore

/// The "TV display" settings, shared by the Mac and the pads so every element can be switched on its own.
public struct LanguageOption: Hashable, Sendable {
    public var code: String
    public var name: String
    public init(code: String, name: String) { self.code = code; self.name = name }
}

public struct TVDisplaySettingsSections: View {
    @Binding var tv: TVDisplaySettings
    var languages: [LanguageOption]

    public init(tv: Binding<TVDisplaySettings>, languages: [LanguageOption] = []) {
        _tv = tv
        self.languages = languages
    }

    public var body: some View {
        Section("Lyrics") {
            Toggle("Previous line", isOn: $tv.showPreviousLine)
            Toggle("Next line", isOn: $tv.showNextLine)
            Toggle("Backing vocals", isOn: $tv.showBackingVocals)
            Toggle("Singer names", isOn: $tv.showSingerNames)
            Toggle("Translation line (on-device AI)", isOn: $tv.showTranslation)
            if tv.showTranslation {
                Picker("Translate the TV into", selection: Binding(get: { tv.translationLanguage ?? "" }, set: { tv.translationLanguage = $0.isEmpty ? nil : $0 })) {
                    Text("Choose a language").tag("")
                    ForEach(languages, id: \.code) { l in Text(l.name).tag(l.code) }
                }
            }
            Toggle("Countdown dots before singing", isOn: $tv.showCountdown)
            Toggle("Word fill on line-synced lyrics", isOn: $tv.estimatedWordWipe)
            VStack(alignment: .leading) {
                Text("Lyric size: \(Int(tv.lyricSize))")
                Slider(value: $tv.lyricSize, in: 56...150, step: 2)
            }
        }
        Section("Background") {
            Picker("Style", selection: $tv.background) {
                Text("Album color blobs").tag(TVBackground.artworkBlobs)
                Text("Blurred artwork").tag(TVBackground.artwork)
                Text("Plain").tag(TVBackground.plain)
            }
            VStack(alignment: .leading) {
                Text("Motion: one drift every \(Int(tv.backgroundSpeed)) s")
                Slider(value: $tv.backgroundSpeed, in: 10...60, step: 2)
            }
        }
        Section("Extras") {
            Toggle("Song info", isOn: $tv.showSongInfo)
            Toggle("Up next", isOn: $tv.showUpNext)
            Toggle("Progress line", isOn: $tv.showProgress)
            Toggle("Join QR code when idle", isOn: $tv.showJoinQR)
        }
        Section {
            Toggle("Pitch guide", isOn: $tv.showPitchGuide)
            Toggle("Live score", isOn: $tv.showLiveScore)
            Toggle("Score reveal", isOn: $tv.showScoreReveal)
            Toggle("Score details", isOn: $tv.showScoreDetails)
            Toggle("Confetti", isOn: $tv.showConfetti)
            VStack(alignment: .leading) {
                Text("Results stay on screen for \(Int(tv.resultSeconds)) s")
                Slider(value: $tv.resultSeconds, in: 7...30, step: 1)
            }
        } header: {
            Text("Pitch and score")
        } footer: {
            Text("The score compares the mic with the melody of the separated vocals.")
        }
    }
}

public struct PartySettingsSections: View {
    @Binding var settings: SingSettings

    public init(settings: Binding<SingSettings>) {
        _settings = settings
    }

    public var body: some View {
        Section("Playback") {
            Toggle("Countdown before each song", isOn: $settings.playback.countdownBetweenSongs)
            Toggle("Play the next song automatically", isOn: $settings.playback.autoAdvance)
            Toggle("Play the original when stems are not ready", isOn: $settings.playback.playOriginalWhenNotReady)
            VStack(alignment: .leading) {
                Text("Default guide vocal: \(Int(settings.playback.defaultGuideVocal * 100))%")
                Slider(value: $settings.playback.defaultGuideVocal, in: 0...1)
            }
        }
        Section("Theme") {
            Picker("Colors", selection: $settings.theme.preset) {
                ForEach(SingTheme.presetIDs, id: \.self) { id in
                    Text(SingTheme(id: id).preset.name).tag(id)
                }
            }
        }
    }
}
