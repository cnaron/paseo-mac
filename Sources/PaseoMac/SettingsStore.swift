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

    // MARK: - Defaults keys

    private let kFontScale = "paseomac.settings.fontScale"
    private let kLineSpacing = "paseomac.settings.lineSpacing"
    private let kBubbleGap = "paseomac.settings.bubbleGap"
    private let kComposerHeight = "paseomac.settings.composerHeight"

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

    // MARK: - Init

    init() {
        let d = UserDefaults.standard
        self.fontScale = d.object(forKey: kFontScale) as? Double ?? 1.0
        self.paragraphLineSpacing = d.object(forKey: kLineSpacing) as? Double ?? 3.0
        self.bubbleGap = d.object(forKey: kBubbleGap) as? Double ?? 14.0
        self.composerHeight = d.object(forKey: kComposerHeight) as? Double ?? 72.0
    }

    // MARK: - Helpers

    func resetToDefaults() {
        fontScale = 1.0
        paragraphLineSpacing = 3.0
        bubbleGap = 14.0
        composerHeight = 72.0
    }

    /// Scales a base point size by `fontScale`. Rounded to 0.5 so fonts stay
    /// crisp at common scales.
    func scaled(_ points: CGFloat) -> CGFloat {
        let raw = points * CGFloat(fontScale)
        return (raw * 2).rounded() / 2
    }
}
