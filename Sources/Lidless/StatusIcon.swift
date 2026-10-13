import AppKit

/// What the menu bar icon says at a glance.
enum StatusIconState {
    /// Nothing is keeping the Mac awake.
    case asleep
    /// The Mac is being kept awake.
    case awake
    /// Closed-lid mode is armed or active.
    case lid

    var accessibilityDescription: String {
        switch self {
        case .asleep: "Lidless: not keeping the Mac awake"
        case .awake: "Lidless: keeping the Mac awake"
        case .lid: "Lidless: closed-lid mode on"
        }
    }
}

/// The menu bar glyphs, drawn in code as template images so macOS tints them for light and dark
/// menu bars, for the highlighted state and for increased contrast.
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(for state: StatusIconState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            draw(state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityDescription
        return image
    }

    private static func draw(_ state: StatusIconState) {
        switch state {
        case .asleep:
            closedEye()
        case .awake:
            openEye(centerY: 9)
        case .lid:
            // The eye stays open above the line of a closed lid.
            openEye(centerY: 10.75)
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: 3.25, y: 3.25))
            lid.line(to: NSPoint(x: 14.75, y: 3.25))
            lid.lineWidth = 1.5
            lid.lineCapStyle = .round
            lid.stroke()
        }
    }

    /// An almond outline with a slit pupil: the lidless eye.
    private static func openEye(centerY: CGFloat) {
        let left = NSPoint(x: 1.5, y: centerY)
        let right = NSPoint(x: 16.5, y: centerY)
        let bulge: CGFloat = 5.4

        let outline = NSBezierPath()
        outline.move(to: left)
        outline.curve(
            to: right,
            controlPoint1: NSPoint(x: 5.2, y: centerY + bulge), controlPoint2: NSPoint(x: 12.8, y: centerY + bulge)
        )
        outline.curve(
            to: left,
            controlPoint1: NSPoint(x: 12.8, y: centerY - bulge), controlPoint2: NSPoint(x: 5.2, y: centerY - bulge)
        )
        outline.close()
        outline.lineWidth = 1.4
        outline.lineJoinStyle = .round
        outline.stroke()

        NSBezierPath(ovalIn: NSRect(x: 9 - 1.35, y: centerY - 2.75, width: 2.7, height: 5.5)).fill()
    }

    /// A lowered eyelid with three lashes.
    private static func closedEye() {
        let strokes = NSBezierPath()
        strokes.move(to: NSPoint(x: 2, y: 10.5))
        strokes.curve(
            to: NSPoint(x: 16, y: 10.5),
            controlPoint1: NSPoint(x: 5.5, y: 5), controlPoint2: NSPoint(x: 12.5, y: 5)
        )
        strokes.move(to: NSPoint(x: 4.5, y: 7.8))
        strokes.line(to: NSPoint(x: 3.2, y: 5.8))
        strokes.move(to: NSPoint(x: 9, y: 6.4))
        strokes.line(to: NSPoint(x: 9, y: 4))
        strokes.move(to: NSPoint(x: 13.5, y: 7.8))
        strokes.line(to: NSPoint(x: 14.8, y: 5.8))
        strokes.lineWidth = 1.4
        strokes.lineCapStyle = .round
        strokes.stroke()
    }
}
