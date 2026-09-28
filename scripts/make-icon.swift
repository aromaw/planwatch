import AppKit
import Foundation

// Draw the small native icon locally; no downloaded artwork or asset dependencies.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let side = CGFloat(pixels)
        NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: side * 0.23, yRadius: side * 0.23).fill()
        let colors = [NSColor(calibratedRed: 0.51, green: 0.83, blue: 0.71, alpha: 1),
                      NSColor(calibratedRed: 0.65, green: 0.67, blue: 0.96, alpha: 1),
                      NSColor(calibratedRed: 0.93, green: 0.74, blue: 0.42, alpha: 1)]
        for (index, width) in [0.59, 0.42, 0.27].enumerated() {
            let y = side * (0.66 - CGFloat(index) * 0.21)
            NSColor.white.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: NSRect(x: side * 0.2, y: y, width: side * 0.6, height: side * 0.095),
                         xRadius: side * 0.0475, yRadius: side * 0.0475).fill()
            colors[index].setFill()
            NSBezierPath(roundedRect: NSRect(x: side * 0.2, y: y, width: side * CGFloat(width), height: side * 0.095),
                         xRadius: side * 0.0475, yRadius: side * 0.0475).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
