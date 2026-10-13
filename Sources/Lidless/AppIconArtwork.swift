import AppKit

/// The app icon, drawn in code. `Lidless --export-icons <dir>` renders it into an `.iconset`, so
/// the repository carries no binary artwork.
enum AppIconArtwork {
    /// Pixel sizes of a complete macOS icon set, with their file names.
    static let iconsetFiles: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]

    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in iconsetFiles {
            try png(side: file.pixels) { draw(side: CGFloat(file.pixels)) }
                .write(to: directory.appendingPathComponent(file.name))
        }
    }

    private static func png(side: Int, drawing: () -> Void) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawing()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// Draws the icon in a `side` × `side` square, on Apple's 1024-point icon grid.
    static func draw(side: CGFloat) {
        let unit = side / 1024
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * unit, y: y * unit) }

        // The rounded tile, with the soft shadow macOS icons sit on.
        let tileRect = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: 186 * unit, yRadius: 186 * unit)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -12 * unit)
        shadow.shadowBlurRadius = 24 * unit
        shadow.set()
        NSColor.black.setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 0.17, green: 0.15, blue: 0.33, alpha: 1),
            NSColor(srgbRed: 0.04, green: 0.04, blue: 0.09, alpha: 1),
        ])?.draw(in: tileRect, angle: -90)

        // Embers behind the eye.
        NSGradient(colors: [
            NSColor(srgbRed: 1.0, green: 0.55, blue: 0.1, alpha: 0.42),
            NSColor(srgbRed: 1.0, green: 0.45, blue: 0.1, alpha: 0),
        ])?.draw(
            fromCenter: point(512, 512), radius: 0, toCenter: point(512, 512), radius: 400 * unit, options: []
        )
        NSGraphicsContext.restoreGraphicsState()

        // The eye: an almond that never closes.
        let almond = NSBezierPath()
        almond.move(to: point(196, 512))
        almond.curve(to: point(828, 512), controlPoint1: point(350, 760), controlPoint2: point(674, 760))
        almond.curve(to: point(196, 512), controlPoint1: point(674, 264), controlPoint2: point(350, 264))
        almond.close()

        NSGraphicsContext.saveGraphicsState()
        almond.addClip()
        NSColor(srgbRed: 0.05, green: 0.04, blue: 0.10, alpha: 1).setFill()
        almond.fill()
        // Iris.
        NSGradient(colorsAndLocations:
            (NSColor(srgbRed: 1.0, green: 0.86, blue: 0.45, alpha: 1), 0),
            (NSColor(srgbRed: 1.0, green: 0.62, blue: 0.14, alpha: 1), 0.55),
            (NSColor(srgbRed: 0.80, green: 0.27, blue: 0.05, alpha: 1), 1)
        )?.draw(
            fromCenter: point(512, 512), radius: 0, toCenter: point(512, 512), radius: 190 * unit, options: []
        )
        NSGraphicsContext.restoreGraphicsState()

        // Slit pupil.
        NSColor(srgbRed: 0.05, green: 0.04, blue: 0.10, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 478 * unit, y: 362 * unit, width: 68 * unit, height: 300 * unit)).fill()

        // Outline last, so its edge stays crisp over the iris.
        NSColor(white: 1, alpha: 0.94).setStroke()
        almond.lineWidth = 34 * unit
        almond.lineJoinStyle = .round
        almond.stroke()
    }
}
