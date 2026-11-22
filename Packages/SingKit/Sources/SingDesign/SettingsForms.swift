#if !os(tvOS)
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
            Toggle("One color per singer in duets", isOn: $tv.showSingerNames)
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
            Picker("Typeface", selection: $tv.lyricFont) {
                Text("SF Pro").tag("default")
                Text("Rounded").tag("rounded")
                Text("Serif").tag("serif")
                Text("Monospaced").tag("mono")
            }
            Stepper("Lines around the current one: \(tv.contextLines)", value: $tv.contextLines, in: 1...3)
        }
        Section("Background") {
            Picker("Style", selection: $tv.background) {
                Text("Album color blobs").tag(TVBackground.artworkBlobs)
                Text("Blurred artwork").tag(TVBackground.artwork)
                Text("Plain").tag(TVBackground.plain)
                Text("Video loop (chosen on the Mac)").tag(TVBackground.video)
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
            Toggle("Fun facts about tonight when idle", isOn: $tv.showFunStats)
            Toggle("Host pairing code in a corner", isOn: $tv.showHostCode)
        }
        Section {
            Toggle("Just for fun: no numbers at all", isOn: $tv.justForFun)
            Toggle("Pitch guide", isOn: $tv.showPitchGuide)
            Toggle("Live score", isOn: $tv.showLiveScore)
            Toggle("Score reveal", isOn: $tv.showScoreReveal)
            Toggle("Score details", isOn: $tv.showScoreDetails)
            Toggle("Confetti", isOn: $tv.showConfetti)
            Toggle("Tonight's leaderboard between songs", isOn: $tv.showLeaderboard)
            Toggle("Latin spelling under other scripts", isOn: $tv.showRomanization)
            Toggle("Applause meter after each song", isOn: $tv.showApplause)
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
            Toggle("Singers take turns in the queue", isOn: $settings.queue.fairRotation)
            Toggle("Queue a crowd favourite when the queue runs dry", isOn: $settings.queue.autoFill)
            Picker("Scoring", selection: $settings.playback.difficulty) {
                Text("Easy").tag("easy")
                Text("Normal").tag("normal")
                Text("Hard").tag("hard")
            }
            Toggle("Even out loudness between songs", isOn: $settings.playback.normalizeLoudness)
            Toggle("Jingle and music for the results", isOn: $settings.playback.resultsMusic)
            if settings.playback.resultsMusic {
                VStack(alignment: .leading) {
                    Text("Results music volume: \(Int(settings.playback.resultsMusicVolume * 100))%")
                    Slider(value: $settings.playback.resultsMusicVolume, in: 0...1)
                }
            }
            Toggle("Turn mics down when feedback howls", isOn: $settings.playback.feedbackProtection)
            Picker("Fade songs in and out", selection: $settings.playback.crossfadeSeconds) {
                Text("Off").tag(0.0)
                Text("2 s").tag(2.0)
                Text("5 s").tag(5.0)
            }
            VStack(alignment: .leading) {
                Text("Default guide vocal: \(Int(settings.playback.defaultGuideVocal * 100))%")
                Slider(value: $settings.playback.defaultGuideVocal, in: 0...1)
            }
        }
        Section {
            Toggle("Record every performance", isOn: $settings.playback.recordPerformances)
            if settings.playback.recordPerformances {
                Picker("Keep recordings", selection: $settings.playback.keepRecordingsDays) {
                    Text("7 days").tag(7.0)
                    Text("30 days").tag(30.0)
                    Text("1 year").tag(365.0)
                    Text("Forever").tag(0.0)
                }
            }
        } header: { Text("Recordings") } footer: {
            Text("Music and voice are recorded on the Mac only. Singers can listen back on their device and take a QR link home; kept recordings are never deleted automatically.")
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

#endif
