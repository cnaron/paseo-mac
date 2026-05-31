import SwiftUI

// MARK: - Color hex helper

extension Color {
    /// `0xRRGGBB` → sRGB Color.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Design tokens
//
// Lifted verbatim from the Claude Design prototype (`paseo-mac.html :root`),
// light theme. v1 ships light-only — `RootView` forces `.aqua` so these render
// true regardless of the system setting. Dark mode is a later, additive pass.

enum DS {
    // surfaces
    static let desktop       = Color(hex: 0xD7D6D2)
    static let sidebarBG     = Color(hex: 0xF5F5F3)
    static let contentBG     = Color(hex: 0xFFFFFF)
    static let elevated      = Color(hex: 0xFFFFFF)
    static let divider       = Color(hex: 0xE7E7E3)
    static let dividerStrong = Color(hex: 0xDCDCD7)
    static let hover         = Color.black.opacity(0.045)
    static let hoverStrong   = Color.black.opacity(0.07)

    // text
    static let text      = Color(hex: 0x1D1D1F)
    static let text2     = Color(hex: 0x6E6E73)
    static let text3     = Color(hex: 0x9A9A9F)
    static let textFaint = Color(hex: 0xB6B6BA)

    // semantic status
    static let green        = Color(hex: 0x34A853)
    static let greenSoftBG  = Color(hex: 0xE6F3E2)
    static let greenSoftTX  = Color(hex: 0x3F8E3A)
    static let cyan         = Color(hex: 0x32ADE6)
    static let red          = Color(hex: 0xE0524B)
    static let redSoftBG    = Color(hex: 0xFBE7E6)
    static let orange       = Color(hex: 0xE08A2B)
    static let orangeSoftBG = Color(hex: 0xFBEEDB)
    static let grayDot      = Color(hex: 0xB3B3B8)

    // code / mono chip
    static let chipBG       = Color(hex: 0xEDEDEB)
    static let chipBGStrong = Color(hex: 0xE6E6E3)
    static let chipTX       = Color(hex: 0x2A2A2D)

    // diff line tints
    static let diffAddBG  = Color(hex: 0xE6F5E9)
    static let diffAddTX  = Color(hex: 0x18794E)
    static let diffDelBG  = Color(hex: 0xFBE9E7)
    static let diffDelTX  = Color(hex: 0xB42318)
    static let diffHunkBG = Color(hex: 0xF0EAFB)
    static let diffHunkTX = Color(hex: 0x7C3AED)

    // syntax highlight palette
    static let tokKey = Color(hex: 0x9326C9)
    static let tokStr = Color(hex: 0xC2410C)
    static let tokCom = Color(hex: 0x8A8A8E)
    static let tokFn  = Color(hex: 0x1750C4)
    static let tokNum = Color(hex: 0x1A7F37)

    // tool badges
    static let badgeEditBG   = Color(hex: 0xE6EEFB)
    static let badgeEditTX   = Color(hex: 0x1F57C4)
    static let badgeScriptBG = Color(hex: 0xEFE8FB)
    static let badgeScriptTX = Color(hex: 0x7C3AED)

    // shape
    enum R {
        static let row: CGFloat      = 8
        static let chip: CGFloat     = 8
        static let card: CGFloat     = 12
        static let bubble: CGFloat   = 15
        static let composer: CGFloat = 17
        static let window: CGFloat   = 11
        static let pill: CGFloat     = 8
    }

    static let sidebarW: CGFloat      = 290
    static let transcriptMaxW: CGFloat = 760

    // shadows (color, radius, y)
    static let shadowCard  = (color: Color.black.opacity(0.05), radius: CGFloat(1),  y: CGFloat(1))
    static let shadowPop   = (color: Color.black.opacity(0.16), radius: CGFloat(15), y: CGFloat(8))
    static let shadowWin   = (color: Color.black.opacity(0.20), radius: CGFloat(35), y: CGFloat(12))

    // type
    static let monoName = "SF Mono"
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Accent palette (user-selectable; terracotta default)
//
// The four swatches from Settings → 外观. Each accent carries its derived tints
// so the user bubble, selected row, focus ring, and send button all stay in key.

struct AccentPalette: Equatable, Sendable {
    let accent: Color
    let press: Color
    let tint: Color   // user bubble fill / send-btn idle fill
    let sel: Color    // selected sidebar row
    let ring: Color   // focus ring / pulse
    let send: Color   // send-btn ready-state warm fill
    let hex: String

    static let terracotta = AccentPalette(
        accent: Color(hex: 0xD97757), press: Color(hex: 0xC2603F),
        tint: Color(hex: 0xF9ECE5), sel: Color(hex: 0xF6ECE6),
        ring: Color(red: 217/255, green: 119/255, blue: 87/255, opacity: 0.32),
        send: Color(hex: 0xFAE4D9), hex: "#d97757"
    )
    static let blue = AccentPalette(
        accent: Color(hex: 0x2C6CE6), press: Color(hex: 0x1F57C4),
        tint: Color(hex: 0xE3EBFC), sel: Color(hex: 0xE7EAF7),
        ring: Color(red: 44/255, green: 108/255, blue: 230/255, opacity: 0.32),
        send: Color(hex: 0xDBE6FD), hex: "#2c6ce6"
    )
    static let sky = AccentPalette(
        accent: Color(hex: 0x5B8DEF), press: Color(hex: 0x4072D6),
        tint: Color(hex: 0xE9EFFD), sel: Color(hex: 0xECF0FB),
        ring: Color(red: 91/255, green: 141/255, blue: 239/255, opacity: 0.32),
        send: Color(hex: 0xE3ECFD), hex: "#5b8def"
    )
    static let teal = AccentPalette(
        accent: Color(hex: 0x2F8F7D), press: Color(hex: 0x247064),
        tint: Color(hex: 0xE0F1EC), sel: Color(hex: 0xE4F0EC),
        ring: Color(red: 47/255, green: 143/255, blue: 125/255, opacity: 0.32),
        send: Color(hex: 0xDCEFE7), hex: "#2f8f7d"
    )

    /// In Settings → 外观 display order: 蓝 / 天蓝 / 青 / 陶土.
    static let all: [AccentPalette] = [blue, sky, teal, terracotta]
    static let names: [String: String] = [
        "#2c6ce6": "蓝", "#5b8def": "天蓝", "#2f8f7d": "青", "#d97757": "陶土",
    ]

    static func named(_ hex: String) -> AccentPalette {
        all.first { $0.hex.lowercased() == hex.lowercased() } ?? terracotta
    }
}

// MARK: - Theme environment
//
// Carries the active accent through the view tree. Read with `@Environment(\.accent)`.

private struct AccentKey: EnvironmentKey {
    static let defaultValue: AccentPalette = .terracotta
}

extension EnvironmentValues {
    var accent: AccentPalette {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}
