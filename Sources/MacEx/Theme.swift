import AppKit
import SwiftUI

/// Shared palette. Dark mode uses layered graphite shades instead of pure black so surfaces stay distinguishable.
enum Theme {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // Base layers, darkest to lightest.
    static let canvasNS = dynamic(rgb(0xFBFBFD), rgb(0x17181C))
    static let sidebarNS = dynamic(rgb(0xF2F2F6), rgb(0x1D1E23))
    static let surfaceNS = dynamic(rgb(0xFFFFFF), rgb(0x22242A))
    static let elevatedNS = dynamic(rgb(0xFFFFFF), rgb(0x2A2C33))
    static let hairlineNS = dynamic(rgb(0x000000, 0.08), rgb(0xFFFFFF, 0.07))
    static let hoverNS = dynamic(rgb(0x000000, 0.045), rgb(0xFFFFFF, 0.055))
    static let accentNS = dynamic(rgb(0x3D6FE0), rgb(0x6B95FF))
    static let selectionNS = dynamic(rgb(0x3D6FE0, 0.14), rgb(0x6B95FF, 0.20))

    static let canvas = Color(nsColor: canvasNS)
    static let sidebar = Color(nsColor: sidebarNS)
    static let surface = Color(nsColor: surfaceNS)
    static let elevated = Color(nsColor: elevatedNS)
    static let hairline = Color(nsColor: hairlineNS)
    static let hover = Color(nsColor: hoverNS)
    static let accent = Color(nsColor: accentNS)
    static let selection = Color(nsColor: selectionNS)

    static let snappy = Animation.spring(response: 0.24, dampingFraction: 0.82)
    static let gentle = Animation.easeOut(duration: 0.18)
}

/// Subtle hover lift and press feedback for card-like buttons.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.015
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.16 : 0), radius: hovering ? 10 : 0, y: hovering ? 5 : 0)
            .animation(Theme.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Plain button style that dips slightly while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.gentle, value: configuration.isPressed)
    }
}

/// Small icon-only toolbar button with a rounded hover plate.
struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Theme.accent : .secondary)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering || active ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(PressableStyle()).help(MenuShortcut.hint(for: help).map { "\(help) (\($0))" } ?? help).accessibilityLabel(help)
            .onHover { hovering = $0 }.animation(Theme.gentle, value: hovering)
    }
}

extension View {
    func hoverLift(_ scale: CGFloat = 1.015) -> some View { modifier(HoverLift(scale: scale)) }
}

/// Every "open this file" goes through here, so behavior is consistent and tests can observe it without launching apps.
@MainActor enum FileOpener {
    static var handler: (URL) -> Void = { NSWorkspace.shared.open($0) }
    static func open(_ url: URL) { handler(url) }
}

/// Finder-style selection rectangle drawn while rubber-band selecting. Never takes clicks.
@MainActor final class MarqueeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.borderWidth = 1
        updateColors()
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.accentNS.withAlphaComponent(0.15).cgColor
            layer?.borderColor = Theme.accentNS.withAlphaComponent(0.7).cgColor
        }
    }
    static func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
