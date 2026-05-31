import SwiftUI
import AppKit

// MARK: - Icon system
//
// The prototype ships a hand-drawn "native-style line icon set". SF Symbols are
// the faithful — and more Mac-native — equivalent, so each design icon name maps
// to its closest SF Symbol. Callers use `DSIcon(name:size:weight:)` with the same
// names the prototype uses, keeping the view code a 1:1 translation of the JSX.

enum DSIconName {
    static func symbol(for name: String) -> String {
        switch name {
        // chevrons / arrows
        case "chevron-down":   return "chevron.down"
        case "chevron-right":  return "chevron.right"
        case "chevron-up":     return "chevron.up"
        case "arrow-up":       return "arrow.up"
        // sidebar / primary
        case "new-chat":       return "square.and.pencil"
        case "chat":           return "bubble.left"
        case "folder":         return "folder"
        case "folder-open":    return "folder"
        case "cloud-slash":    return "icloud.slash"
        case "sparkle":        return "sparkles"
        // header / toolbar
        case "dots":           return "ellipsis"
        case "sidebar-toggle": return "sidebar.right"
        case "plus":           return "plus"
        case "search":         return "magnifyingglass"
        case "branch":         return "arrow.triangle.branch"
        case "github":         return "chevron.left.forwardslash.chevron.right" // octocat substitute (no SF Symbol)
        // utility bar
        case "gear":           return "gearshape"
        case "help":           return "questionmark.circle"
        case "archive":        return "archivebox"
        case "filter":         return "line.3.horizontal.decrease"
        case "person":         return "person.crop.circle.fill"
        case "import":         return "square.and.arrow.down"
        // transcript glyphs
        case "copy":           return "doc.on.doc"
        case "clock":          return "clock"
        case "bolt":           return "bolt.fill"
        case "shield":         return "shield"
        case "shield-check":   return "checkmark.shield"
        case "question-chat":  return "questionmark.bubble"
        case "alert":          return "exclamationmark.triangle"
        case "checklist":      return "checklist"
        case "check":          return "checkmark"
        case "check-sm":       return "checkmark"
        case "x":              return "xmark"
        case "stop":           return "stop.fill"
        case "refresh":        return "arrow.clockwise"
        // tool icons
        case "file-text":      return "doc.text"
        case "edit":           return "pencil"
        case "terminal":       return "terminal"
        case "terminal-box":   return "apple.terminal"
        case "image":          return "photo"
        case "monitor":        return "display"
        case "lock-open":      return "lock.open"
        case "lock":           return "lock"
        case "link":           return "link"
        case "trash":          return "trash"
        case "moon":           return "moon"
        case "external":       return "arrow.up.right"
        case "doc":            return "doc"
        case "diffstat":       return "plus.forwardslash.minus"
        // settings / charts
        case "chart":          return "chart.bar"
        case "palette":        return "paintpalette"
        case "sliders":        return "slider.horizontal.3"
        case "bell":           return "bell"
        default:               return "questionmark"
        }
    }
}

/// One icon, sized in points to match the prototype's pixel sizes. `weight`
/// stands in for the prototype's stroke width (≈1.7 → `.regular`/`.medium`).
struct DSIcon: View {
    let name: String
    var size: CGFloat = 18
    var weight: Font.Weight = .regular

    var body: some View {
        Image(systemName: DSIconName.symbol(for: name))
            .font(.system(size: size, weight: weight))
            .imageScale(.medium)
    }
}

// MARK: - Provider glyph
//
// Real brand logo (claude terracotta spark / codex / gemini) from the bundle,
// with a sparkles fallback for any other provider. Mirrors the prototype's
// `ProviderGlyph` and the existing `ProviderIcon` loader.

struct ProviderGlyph: View {
    let provider: String?
    var size: CGFloat = 17

    var body: some View {
        if let img = Self.brandImage(provider) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            DSIcon(name: "sparkle", size: size - 1, weight: .medium)
                .foregroundStyle(DS.text2)
        }
    }

    static func brandImage(_ provider: String?) -> NSImage? {
        guard let p = provider, ["claude", "codex", "gemini"].contains(p) else { return nil }
        let img = NSImage(named: p)
            ?? Bundle.main.path(forResource: p, ofType: "png").flatMap { NSImage(contentsOfFile: $0) }
        img?.size = NSSize(width: 32, height: 32)
        return img
    }
}
