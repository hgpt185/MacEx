import AppKit
import ImageIO

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Scripts/GenerateIcon.swift <destination.iconset>")
}
let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == image.height else {
    fatalError("Expected a square source image at \(sourceURL.path)")
}
// Normalize transparent margins without editing the supplied source artwork. Ignore
// nearly invisible alpha noise so an isolated stray pixel cannot shrink the logo.
let alpha = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
alpha.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
let rgba = alpha.data!.assumingMemoryBound(to: UInt8.self)
var left = image.width, top = image.height, right = -1, bottom = -1
for y in 0..<image.height {
    for x in 0..<image.width where rgba[y * alpha.bytesPerRow + x * 4 + 3] > 8 {
        left = min(left, x); top = min(top, y); right = max(right, x); bottom = max(bottom, y)
    }
}
guard right >= left, bottom >= top,
      let artwork = image.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else {
    fatalError("Expected visible artwork at \(sourceURL.path)")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        let artworkScale = Double(pixels) * 0.90 / Double(max(artwork.width, artwork.height))
        let width = Double(artwork.width) * artworkScale, height = Double(artwork.height) * artworkScale
        context.draw(artwork, in: CGRect(x: (Double(pixels) - width) / 2, y: (Double(pixels) - height) / 2,
                                       width: width, height: height))
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
