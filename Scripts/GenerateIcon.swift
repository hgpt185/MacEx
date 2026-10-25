import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        NSAffineTransform().apply { $0.scale(by: factor); $0.concat() }
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 205, yRadius: 205).fill()
        NSColor(calibratedRed: 0.40, green: 0.68, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 225, y: 350, width: 570, height: 355), xRadius: 55, yRadius: 55).fill()
        NSBezierPath(roundedRect: NSRect(x: 225, y: 620, width: 238, height: 125), xRadius: 35, yRadius: 35).fill()
        NSColor(calibratedRed: 0.12, green: 0.40, blue: 0.86, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 225, y: 278, width: 570, height: 345), xRadius: 55, yRadius: 55).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 466, y: 278, width: 66, height: 243), xRadius: 27, yRadius: 27).fill()
        NSBezierPath(roundedRect: NSRect(x: 466, y: 472, width: 176, height: 54), xRadius: 25, yRadius: 25).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
extension NSAffineTransform {
    func apply(_ body: (NSAffineTransform) -> Void) { body(self) }
}
