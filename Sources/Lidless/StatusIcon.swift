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

/// The menu bar glyphs: the small-size cut of the logo (design/logo/menubar/), drawn in code as
/// template images so macOS tints them for light and dark menu bars, for the highlighted state
/// and for increased contrast.
///
/// The logo's lower lid is a crescent that tapers to a point; below 24 px that taper turns to
/// mush, so here it is a line of constant weight. Geometry is in points on an 18-point square,
/// origin bottom left.
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)
    private static let lineWidth: CGFloat = 1.6

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
            // The eye at rest: the lid alone.
            lowerLid()
        case .awake:
            // The lidless eye: a pupil nothing can close over.
            pupil()
            lowerLid()
        case .lid:
            // The laptop's lid, above the eye and unable to come down on it.
            closedLid()
            pupil()
            lowerLid()
        }
    }

    /// An arc of radius 9.1 around (9, 14.1), 53 degrees either side of straight down.
    private static func lowerLid() {
        let lid = NSBezierPath()
        lid.appendArc(
            withCenter: NSPoint(x: 9, y: 14.1), radius: 9.1, startAngle: 217.18, endAngle: 322.82, clockwise: false
        )
        lid.lineWidth = lineWidth
        lid.lineCapStyle = .round
        lid.stroke()
    }

    private static func pupil() {
        NSBezierPath(ovalIn: NSRect(x: 5.9, y: 8.3, width: 6.2, height: 6.2)).fill()
    }

    private static func closedLid() {
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: 4.5, y: 16.7))
        bar.line(to: NSPoint(x: 13.5, y: 16.7))
        bar.lineWidth = lineWidth
        bar.lineCapStyle = .round
        bar.stroke()
    }
}
