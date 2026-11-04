import AppKit

/// App-drawn folder artwork: a soft two-panel folder with a glassy front and a light top edge.
/// Drawn with vector paths at any size, so it stays crisp in the list (20 pt) and the grid (72 pt).
@MainActor enum FolderArt {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 128, height: 128), flipped: true) { rect in
            draw(in: rect); return true
        }
        image.accessibilityDescription = "Folder"
        return image
    }()

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func draw(in rect: NSRect) {
        let w = rect.width, h = rect.height
        let top = h * 0.17, bottom = h * 0.86, left = w * 0.06, right = w * 0.94
        let radius = w * 0.07

        // Back panel with tab.
        let back = NSBezierPath()
        let tabEnd = left + (right - left) * 0.40
        let shoulder = top + h * 0.075
        back.move(to: NSPoint(x: left + radius, y: top))
        back.line(to: NSPoint(x: tabEnd - radius * 0.6, y: top))
        back.curve(to: NSPoint(x: tabEnd + radius * 0.9, y: shoulder), controlPoint1: NSPoint(x: tabEnd, y: top), controlPoint2: NSPoint(x: tabEnd + radius * 0.2, y: shoulder))
        back.line(to: NSPoint(x: right - radius, y: shoulder))
        back.appendArc(from: NSPoint(x: right, y: shoulder), to: NSPoint(x: right, y: shoulder + radius), radius: radius)
        back.line(to: NSPoint(x: right, y: bottom - radius))
        back.appendArc(from: NSPoint(x: right, y: bottom), to: NSPoint(x: right - radius, y: bottom), radius: radius)
        back.line(to: NSPoint(x: left + radius, y: bottom))
        back.appendArc(from: NSPoint(x: left, y: bottom), to: NSPoint(x: left, y: bottom - radius), radius: radius)
        back.line(to: NSPoint(x: left, y: top + radius))
        back.appendArc(from: NSPoint(x: left, y: top), to: NSPoint(x: left + radius, y: top), radius: radius)
        back.close()
        NSGradient(starting: color(0x4F7FE6), ending: color(0x3A63C9))?.draw(in: back, angle: 90)

        // Paper sheet peeking out.
        let paper = NSBezierPath(roundedRect: NSRect(x: left + w * 0.09, y: shoulder + h * 0.05, width: (right - left) - w * 0.18, height: h * 0.30), xRadius: radius * 0.5, yRadius: radius * 0.5)
        color(0xF4F7FF, 0.92).setFill(); paper.fill()

        // Glassy front panel.
        let frontTop = top + h * 0.27
        let front = NSBezierPath(roundedRect: NSRect(x: left, y: frontTop, width: right - left, height: bottom - frontTop), xRadius: radius, yRadius: radius)
        NSGradient(colors: [color(0x8DB6FF), color(0x6A98F7), color(0x5585EC)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)?.draw(in: front, angle: 90)

        // Top highlight and fine edge.
        NSGraphicsContext.saveGraphicsState()
        front.addClip()
        let shine = NSBezierPath(rect: NSRect(x: left, y: frontTop, width: right - left, height: h * 0.018))
        color(0xFFFFFF, 0.55).setFill(); shine.fill()
        NSGraphicsContext.restoreGraphicsState()
        color(0x2B4FA8, 0.35).setStroke(); front.lineWidth = max(0.5, w * 0.006); front.stroke()
    }
}
