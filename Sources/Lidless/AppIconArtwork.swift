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

    /// Draws the icon in a `side` × `side` square, on Apple's 1024-point icon grid. Same artwork
    /// as design/logo/app-icon.svg: the mark in paper and ember on an ink tile.
    static func draw(side: CGFloat) {
        let unit = side / 1024
        let ink = (top: NSColor(srgbRed: 0.149, green: 0.149, blue: 0.176, alpha: 1),
                   bottom: NSColor(srgbRed: 0.063, green: 0.063, blue: 0.075, alpha: 1))
        let paper = NSColor(srgbRed: 0.957, green: 0.949, blue: 0.925, alpha: 1)
        let ember = NSColor(srgbRed: 0.961, green: 0.651, blue: 0.231, alpha: 1)

        // The rounded tile, with the soft shadow macOS icons sit on.
        let tileRect = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185.4 * unit, yRadius: 185.4 * unit)
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
        NSGradient(colors: [ink.top, ink.bottom])?.draw(in: tileRect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // The mark, drawn on its own 256-point canvas (origin bottom left) and scaled so that it
        // spans 560 of the tile's 824 points, a touch above the middle.
        let scale: CGFloat = 560.0 / 216.0
        NSGraphicsContext.saveGraphicsState()
        let placement = NSAffineTransform()
        placement.translateX(by: (512 - 128 * scale) * unit, yBy: (518 - 130 * scale) * unit)
        placement.scale(by: scale * unit)
        placement.concat()

        // Lower lid: a crescent between two arcs that share their ends at (20,134) and (236,134).
        let lid = NSBezierPath()
        lid.move(to: NSPoint(x: 20, y: 134))
        lid.appendArc(
            withCenter: NSPoint(x: 128, y: 189.36), radius: 121.36, startAngle: 207.14, endAngle: 332.86, clockwise: false
        )
        lid.appendArc(
            withCenter: NSPoint(x: 128, y: 259.8), radius: 165.8, startAngle: 310.65, endAngle: 229.35, clockwise: true
        )
        lid.close()
        paper.setFill()
        lid.fill()

        // The pupil nothing closes over.
        ember.setFill()
        NSBezierPath(ovalIn: NSRect(x: 86, y: 108, width: 84, height: 84)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
