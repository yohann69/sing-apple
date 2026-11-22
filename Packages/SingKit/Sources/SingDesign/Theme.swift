import Foundation
import SwiftUI
import SingCore

public struct SingThemeFile: Codable, Sendable {
    public struct Preset: Codable, Sendable, Hashable {
        public var name: String
        public var dark: Bool
        public var accent: String
        public var accentSoft: String
        public var background: String
        public var backgroundBlobs: [String]
        public var text: String
        public var textSecondary: String
        public var lyricDim: String
        public var success: String
        public var warning: String
        public var danger: String
    }

    public struct LyricStyle: Codable, Sendable {
        public var weight: String
        public var design: String
        public var activeScale: Double
        public var previousScale: Double
        public var nextScale: Double
        public var backgroundVocalScale: Double
    }

    public struct Motion: Codable, Sendable {
        public struct Spring: Codable, Sendable { public var response: Double; public var damping: Double }
        public var spring: Spring
        public var lineTransition: Double
        public var blobDrift: Double
    }

    public var version: Int
    public var `default`: String
    public var presets: [String: Preset]
    public var singers: [String]
    public var lyrics: LyricStyle
    public var motion: Motion

    public static let bundled: SingThemeFile = {
        guard let url = Bundle.module.url(forResource: "sing-theme", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SingThemeFile.self, from: data)
        else { fatalError("sing-theme.json missing or invalid") }
        return file
    }()
}

public struct SingTheme: Sendable, Equatable {
    public let id: String
    public let preset: SingThemeFile.Preset
    public let file: SingThemeFile
    /// TV setting overriding the lyric typeface: "rounded", "serif" or "mono".
    public var fontStyle: String?

    public static func == (a: SingTheme, b: SingTheme) -> Bool { a.id == b.id && a.fontStyle == b.fontStyle }

    public init(id: String? = nil, file: SingThemeFile = .bundled) {
        let key = id.flatMap { file.presets[$0] != nil ? $0 : nil } ?? file.default
        self.id = key
        self.preset = file.presets[key]!
        self.file = file
    }

    public static let ember = SingTheme(id: "ember")

    public var accent: Color { Color(hex: preset.accent) }
    public var accentSoft: Color { Color(hex: preset.accentSoft) }
    public var background: Color { Color(hex: preset.background) }
    public var blobs: [Color] { preset.backgroundBlobs.map(Color.init(hex:)) }
    public var text: Color { Color(hex: preset.text) }
    public var textSecondary: Color { Color(hex: preset.textSecondary) }
    public var lyricDim: Color { Color(hex: preset.lyricDim) }
    public var success: Color { Color(hex: preset.success) }
    public var warning: Color { Color(hex: preset.warning) }
    public var danger: Color { Color(hex: preset.danger) }
    public var colorScheme: ColorScheme { preset.dark ? .dark : .light }

    public var spring: Animation {
        .spring(response: file.motion.spring.response, dampingFraction: file.motion.spring.damping)
    }

    public func lyricFont(size: CGFloat) -> Font {
        let weight: Font.Weight = switch file.lyrics.weight {
        case "heavy": .heavy
        case "semibold": .semibold
        default: .bold
        }
        let design: Font.Design = switch fontStyle ?? file.lyrics.design {
        case "rounded": .rounded
        case "serif": .serif
        case "mono": .monospaced
        default: .default
        }
        return .system(size: size, weight: weight, design: design)
    }

    public static var presetIDs: [String] { SingThemeFile.bundled.presets.keys.sorted() }
}

private struct SingThemeKey: EnvironmentKey {
    static let defaultValue = SingTheme.ember
}

public extension EnvironmentValues {
    var singTheme: SingTheme {
        get { self[SingThemeKey.self] }
        set { self[SingThemeKey.self] = newValue }
    }
}

public extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

public extension Singer {
    var color: Color { Color(hex: colorHex) }
}
