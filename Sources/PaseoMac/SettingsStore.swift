import Foundation
import Observation

/// User-facing appearance knobs, persisted in `UserDefaults` and observed by
/// every view that cares about typography. Kept intentionally small: font
/// scale, paragraph line spacing, and the gap between bubbles.
@MainActor
@Observable
final class SettingsStore {

    // MARK: - Knob ranges

    static let fontScaleRange: ClosedRange<Double> = 0.85...1.5
    static let lineSpacingRange: ClosedRange<Double> = 0...10
    static let bubbleGapRange: ClosedRange<Double> = 8...28
    static let composerHeightRange: ClosedRange<Double> = 44...420
    /// Design v1 transcript body size (prototype slider 13–18).
    static let fontSizeRange: ClosedRange<Double> = 13...18

    // MARK: - Defaults keys

    private let kFontScale = "paseomac.settings.fontScale"
    private let kLineSpacing = "paseomac.settings.lineSpacing"
    private let kBubbleGap = "paseomac.settings.bubbleGap"
    private let kComposerHeight = "paseomac.settings.composerHeight"
    private let kAccent = "paseomac.settings.accentHex"
    private let kFontSize = "paseomac.settings.fontSize"
    private let kDensity = "paseomac.settings.density"

    // MARK: - Published state

    var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: kFontScale) }
    }
    var paragraphLineSpacing: Double {
        didSet { UserDefaults.standard.set(paragraphLineSpacing, forKey: kLineSpacing) }
    }
    var bubbleGap: Double {
        didSet { UserDefaults.standard.set(bubbleGap, forKey: kBubbleGap) }
    }
    var composerHeight: Double {
        didSet { UserDefaults.standard.set(composerHeight, forKey: kComposerHeight) }
    }

    // Design v1 prefs (prototype Settings → 外观)
    /// Accent hex, e.g. "#d97757". Drives the whole accent palette.
    var accentHex: String {
        didSet { UserDefaults.standard.set(accentHex, forKey: kAccent) }
    }
    /// Transcript body size in points (13–18).
    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: kFontSize) }
    }
    /// "spacious" | "compact" — controls inter-bubble spacing.
    var density: String {
        didSet { UserDefaults.standard.set(density, forKey: kDensity) }
    }

    /// Resolved accent palette for the current `accentHex`.
    var accentPalette: AccentPalette { AccentPalette.named(accentHex) }
    /// Gap between transcript bubbles for the current density (prototype 18/12).
    var bubbleGapPt: CGFloat { density == "compact" ? 12 : 18 }

    // MARK: - Init

    init() {
        let d = UserDefaults.standard
        self.fontScale = d.object(forKey: kFontScale) as? Double ?? 1.0
        self.paragraphLineSpacing = d.object(forKey: kLineSpacing) as? Double ?? 5.0
        self.bubbleGap = d.object(forKey: kBubbleGap) as? Double ?? 14.0
        let storedH = d.object(forKey: kComposerHeight) as? Double
        // Reset any prior fixed-height default (72, 52) to 44 for auto-grow
        self.composerHeight = (storedH == nil || storedH == 72.0 || storedH == 52.0) ? 44.0 : storedH!
        self.accentHex = d.string(forKey: kAccent) ?? "#d97757"
        self.fontSize = d.object(forKey: kFontSize) as? Double ?? 15.5
        self.density = d.string(forKey: kDensity) ?? "spacious"
    }

    // MARK: - Helpers

    func resetToDefaults() {
        fontScale = 1.0
        paragraphLineSpacing = 5.0
        bubbleGap = 14.0
        composerHeight = 44.0
    }

    /// Scales a base point size by `fontScale`. Rounded to 0.5 so fonts stay
    /// crisp at common scales.
    func scaled(_ points: CGFloat) -> CGFloat {
        let raw = points * CGFloat(fontScale)
        return (raw * 2).rounded() / 2
    }
}
