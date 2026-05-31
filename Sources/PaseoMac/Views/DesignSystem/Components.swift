import SwiftUI

// MARK: - Icon button (.iconbtn / .iconbtn.sm)

struct IconButton: View {
    let icon: String
    var box: CGFloat = 28
    var glyph: CGFloat = 18
    var weight: Font.Weight = .regular
    var tint: Color = DS.text2
    var help: String = ""
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            DSIcon(name: icon, size: glyph, weight: weight)
                .foregroundStyle(hover ? DS.text : tint)
                .frame(width: box, height: box)
                .background(
                    hover ? DS.hover : Color.clear,
                    in: RoundedRectangle(cornerRadius: box >= 28 ? 7 : 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Animated thinking dots (.tdots)

struct ThinkingDots: View {
    var color: Color = DS.text2
    var dot: CGFloat = 5
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color.opacity(phase == i ? 0.95 : 0.32))
                    .frame(width: dot, height: dot)
                    .animation(.easeInOut(duration: 0.35), value: phase)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 220_000_000)
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: - Segmented control (.seg2)

struct Seg2<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { v in
                let on = v == selection
                Text(label(v))
                    .font(.system(size: 12.5, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? DS.text : DS.text2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = v }
            }
        }
        .padding(2)
        .background(DS.chipBG, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Toggle switch (.switch)

struct DSSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? accent.accent : DS.dividerStrong)
                .frame(width: 40, height: 24)
            Circle()
                .fill(.white)
                .frame(width: 20, height: 20)
                .padding(2)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        }
        .frame(width: 40, height: 24)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() } }
    }
}

// MARK: - Surfaces & helpers

extension View {
    /// Bordered card (.icard / .tool-cluster / .codeblock).
    func dsCard(radius: CGFloat = DS.R.card, fill: Color = DS.contentBG, border: Color = DS.divider) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: 1))
    }

    /// White, bordered pill surface (.pillbtn / .hdr-pill) — wrap a Menu/Button label.
    func pillSurface(radius: CGFloat = 9, height: CGFloat = 30, hpad: CGFloat = 11) -> some View {
        self
            .padding(.horizontal, hpad)
            .frame(height: height)
            .background(DS.contentBG, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(DS.dividerStrong, lineWidth: 1))
    }

    /// Drop shadow from a DS shadow token tuple.
    func dsShadow(_ token: (color: Color, radius: CGFloat, y: CGFloat)) -> some View {
        self.shadow(color: token.color, radius: token.radius, y: token.y)
    }
}

// MARK: - Hover row background (.chat-row:hover / .pop-item)

/// Wraps row content with a hover/selected background — used by list rows.
struct HoverRow<Content: View>: View {
    var selected: Bool = false
    var radius: CGFloat = DS.R.row
    var selectedFill: Color? = nil
    @Environment(\.accent) private var accent
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(selected ? (selectedFill ?? accent.sel) : (hover ? DS.hover : Color.clear))
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}
