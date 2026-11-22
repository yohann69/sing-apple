#if !os(tvOS)
import SingCore
import SwiftUI

/// A singer's own choices, edited on the Mac or on their device.
public struct SingerPrefsForm: View {
    @Binding var prefs: SingerPrefs

    public init(prefs: Binding<SingerPrefs>) { _prefs = prefs }

    static func note(_ m: Double) -> String {
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        let n = Int(m.rounded())
        return names[((n % 12) + 12) % 12] + String(n / 12 - 1)
    }

    public var body: some View {
        Section("Privacy") {
            Toggle("Hide my score", isOn: $prefs.hideScore)
            Toggle("Leave me out of leaderboards", isOn: $prefs.hideFromLeaderboard)
            Toggle("Leave me out of the stats", isOn: $prefs.hideStats)
        }
        Section {
            Picker("Mic effect", selection: Binding(get: { prefs.micPreset ?? "" }, set: { prefs.micPreset = $0.isEmpty ? nil : $0 })) {
                Text("Party setting").tag("")
                ForEach(MicPreset.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
            }
            Toggle("My own guide vocal level", isOn: Binding(get: { prefs.guideVocal != nil }, set: { prefs.guideVocal = $0 ? 0.2 : nil }))
            if let g = prefs.guideVocal {
                VStack(alignment: .leading) {
                    Text("Guide vocal: \(Int(g * 100))%")
                    Slider(value: Binding(get: { g }, set: { prefs.guideVocal = $0 }), in: 0...1)
                }
            }
            Stepper(value: $prefs.keyOffset, in: -6...6) {
                LabeledContent("Key for my songs", value: prefs.keyOffset == 0 ? "Original" : "\(prefs.keyOffset > 0 ? "+" : "")\(prefs.keyOffset)")
            }
            Picker("Name on the TV", selection: $prefs.nameStyle) {
                Text("Emoji and name").tag("both")
                Text("Name").tag("name")
                Text("Emoji").tag("emoji")
            }
        } header: { Text("When I sing") }
        if let lo = prefs.rangeLow, let hi = prefs.rangeHigh {
            Section {
                LabeledContent("Comfortable range", value: "\(Self.note(lo)) to \(Self.note(hi))")
            } footer: { Text("Learned from your songs; used to suggest a key.") }
        }
    }
}

public struct MicSettingsSection: View {
    @Binding var playback: PlaybackSettings
    var channels: Int

    public init(playback: Binding<PlaybackSettings>, channels: Int) {
        _playback = playback
        self.channels = channels
    }

    public var body: some View {
        Section {
            if channels > 1 {
                Toggle("Separate volume for each mic", isOn: $playback.separateMics)
                if playback.separateMics {
                    ForEach(0..<min(4, channels), id: \.self) { c in
                        VStack(alignment: .leading) {
                            Text("Mic \(c + 1): \(Int(gain(c) * 100))%")
                            Slider(value: Binding(get: { gain(c) }, set: { setGain(c, $0) }), in: 0...1.5)
                        }
                    }
                }
                ForEach(0..<min(4, channels), id: \.self) { slot in
                    Picker(slot == 0 ? "First singer uses" : "Singer \(slot + 1) uses", selection: Binding(get: { playback.micSlots.indices.contains(slot) ? playback.micSlots[slot] : slot }, set: { v in
                        while playback.micSlots.count <= slot { playback.micSlots.append(playback.micSlots.count) }
                        playback.micSlots[slot] = v
                    })) {
                        ForEach(0..<min(4, channels), id: \.self) { Text("Mic \($0 + 1)").tag($0) }
                    }
                }
            }
            VStack(alignment: .leading) {
                Text(playback.pitchCorrection == 0 ? "Pitch correction: off" : "Pitch correction: \(Int(playback.pitchCorrection * 100))%")
                Slider(value: $playback.pitchCorrection, in: 0...1, step: 0.05)
            }
        } header: { Text("Microphones") } footer: {
            Text(channels > 1 ? "\(channels) mic inputs found. Each singer is scored on their own mic." : "Plug in a multichannel interface or several USB mics to give each singer a mic.")
        }
    }

    private func gain(_ c: Int) -> Double { playback.micChannelGains.indices.contains(c) ? playback.micChannelGains[c] : 1 }
    private func setGain(_ c: Int, _ v: Double) {
        while playback.micChannelGains.count <= c { playback.micChannelGains.append(1) }
        playback.micChannelGains[c] = v
    }
}

/// Who may change each part of the settings.
public struct LocksSection: View {
    @Binding var locks: [String: String]

    public init(locks: Binding<[String: String]>) { _locks = locks }

    static let sections = [("tv", "TV display"), ("playback", "Playback and mics"), ("queue", "Queue rules"), ("theme", "Theme")]

    public var body: some View {
        Section {
            ForEach(Self.sections, id: \.0) { key, name in
                Picker(name, selection: Binding(get: { locks[key] ?? "hosts" }, set: { locks[key] = $0 == "hosts" ? nil : $0 })) {
                    Text("Guests too").tag("guests")
                    Text("Host pads").tag("hosts")
                    Text("Only this Mac").tag("mac")
                }
            }
        } header: { Text("Who can change what") }
    }
}

public struct AuditLogSection: View {
    var entries: [AuditEntry]
    public init(entries: [AuditEntry]) { self.entries = entries }

    public var body: some View {
        Section("Activity") {
            if entries.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
            ForEach(entries.prefix(60)) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(e.who) \(e.action)")
                    Text(e.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

public struct YearRecapCard: View {
    var year: YearInKaraoke
    public init(year: YearInKaraoke) { self.year = year }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(year.year) in karaoke").font(.title2.bold())
            Text("\(year.songs) songs · \(year.minutes) minutes · \(year.nights) nights").font(.headline)
            if let s = year.topSong { Text("Most sung: \(s)") }
            if let a = year.topArtist { Text("Favourite artist: \(a)") }
            if let b = year.bestScore, let s = year.bestScoreSong { Text("Best score: \(b) on \(s)") }
            if let p = year.favoriteDuetPartner { Text("Favourite duet partner: \(p)") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular.tint(.orange.opacity(0.2)), in: RoundedRectangle(cornerRadius: 22))
    }
}
#endif
