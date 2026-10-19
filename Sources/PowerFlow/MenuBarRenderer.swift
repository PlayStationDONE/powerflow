import AppKit

/// Draws the menu-bar item into an `NSImage`.
///
/// The look follows Mectrics: one image assigned to the status button gives
/// pixel-precise drawing and correct light/dark adaptation without subview
/// layout, and text sits right-aligned in a slot sized from a worst-case
/// template so the item never changes width as the value changes. A menu bar
/// that resizes every second shoves its neighbours around.
enum MenuBarRenderer {
    /// Everything a drawn image is derived from. Handing AppKit an image costs far
    /// more than drawing one (it invalidates the item and round-trips to the window
    /// server), so an unchanged item is left alone.
    struct Inputs: Equatable {
        let style: Settings.MenuBarStyle
        let percent: Int
        let isCharging: Bool
        let watts: Int
        /// Recent system load in watts, oldest first. Empty unless the style charts it.
        let samples: [Double]
        let accent: NSColor
        let showIcon: Bool
        let appearanceName: NSAppearance.Name
    }

    // MARK: - Metrics

    static let height: CGFloat = 20
    private static let sparkWidth: CGFloat = 20
    private static let gap: CGFloat = 4
    /// Leading space taken by the embedded icon (glyph + gap).
    private static let iconSlot: CGFloat = 30
    private static let iconSize = NSSize(width: 26, height: 18)
    private static let batteryWidth: CGFloat = 32
    /// Lower bound of the sparkline's y-axis. An idle Mac stays visibly flat, and a
    /// real load still scales the chart to its own peak.
    static let sparklineFloor: Double = 10

    static let textFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let batteryLabelFont = NSFont.monospacedDigitSystemFont(
        ofSize: 7.5, weight: .bold
    )

    /// Worst-case text for each style; real values must never exceed its width.
    static func template(for style: Settings.MenuBarStyle) -> String {
        switch style {
        case .iconAndPercent: return "100%"
        case .iconAndWatts, .wattsGraph: return "999W"
        case .iconOnly, .batteryGlyph: return ""
        }
    }

    static func drawsSparkline(_ style: Settings.MenuBarStyle) -> Bool {
        style == .wattsGraph
    }

    /// The battery glyph is itself the icon, so a leading icon would repeat it.
    static func drawsIcon(_ inputs: Inputs) -> Bool {
        inputs.showIcon && inputs.style != .batteryGlyph
    }

    private static var reservedTextWidth: [Settings.MenuBarStyle: CGFloat] = [:]

    private static func textWidth(for style: Settings.MenuBarStyle) -> CGFloat {
        if let cached = reservedTextWidth[style] { return cached }
        let width = ceil(
            (template(for: style) as NSString).size(withAttributes: [.font: textFont]).width
        )
        reservedTextWidth[style] = width
        return width
    }

    static func text(for inputs: Inputs) -> String {
        switch inputs.style {
        case .iconAndPercent: return "\(inputs.percent)%"
        case .iconAndWatts, .wattsGraph: return "\(inputs.watts)W"
        case .iconOnly, .batteryGlyph: return ""
        }
    }

    // MARK: - Rendering

    /// The PowerFlow glyph, drawn tinted rather than as a template so it composes
    /// with the text and chart in a single image.
    static func render(_ inputs: Inputs, icon: NSImage?, appearance: NSAppearance) -> NSImage {
        let textWidth = textWidth(for: inputs.style)
        let contentWidth: CGFloat
        switch inputs.style {
        case .batteryGlyph: contentWidth = batteryWidth
        case .wattsGraph: contentWidth = textWidth + gap + sparkWidth
        default: contentWidth = max(textWidth, 12)
        }
        let leading: CGFloat = (drawsIcon(inputs) && icon != nil) ? iconSlot : 0
        let image = NSImage(size: NSSize(width: max(leading + contentWidth, 8), height: height))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: NSColor.labelColor,
        ]

        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            if leading > 0, let icon { drawIcon(icon) }
            switch inputs.style {
            case .iconOnly:
                break
            case .iconAndPercent, .iconAndWatts:
                drawRightAligned(text(for: inputs), attrs: attrs, slot: leading + textWidth)
            case .wattsGraph:
                drawRightAligned(text(for: inputs), attrs: attrs, slot: leading + textWidth)
                drawSparkline(
                    inputs.samples,
                    in: NSRect(x: leading + textWidth + gap, y: 3,
                               width: sparkWidth, height: height - 6),
                    accent: inputs.accent
                )
            case .batteryGlyph:
                drawBattery(
                    level: Double(inputs.percent) / 100,
                    charging: inputs.isCharging,
                    in: NSRect(x: 0, y: 0, width: batteryWidth, height: height)
                )
            }
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func drawIcon(_ icon: NSImage) {
        let origin = NSPoint(x: 0, y: (height - iconSize.height) / 2)
        let rect = NSRect(origin: origin, size: iconSize)
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.labelColor.set()
        rect.fill(using: .sourceAtop)
    }

    /// Draws `text` right-aligned so its right edge sits at `slot`.
    private static func drawRightAligned(
        _ text: String, attrs: [NSAttributedString.Key: Any], slot: CGFloat
    ) {
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: slot - ceil(size.width), y: (height - size.height) / 2),
            withAttributes: attrs
        )
    }

    /// Filled line chart over the recent window, scaled to its own peak.
    private static func drawSparkline(_ values: [Double], in rect: NSRect, accent: NSColor) {
        guard values.count > 1 else { return }
        let maxV = max(values.max() ?? 0, sparklineFloor, 0.0001)
        let stepX = rect.width / CGFloat(values.count - 1)

        func point(_ i: Int) -> NSPoint {
            let y = rect.minY + CGFloat(values[i] / maxV) * rect.height
            return NSPoint(x: rect.minX + CGFloat(i) * stepX,
                           y: min(max(y, rect.minY), rect.maxY))
        }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: rect.minX, y: rect.minY))
        for i in 0..<values.count { fill.line(to: point(i)) }
        fill.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        fill.close()
        accent.withAlphaComponent(0.2).setFill()
        fill.fill()

        let line = NSBezierPath()
        line.lineWidth = 1.2
        line.lineJoinStyle = .round
        line.move(to: point(0))
        for i in 1..<values.count { line.line(to: point(i)) }
        accent.setStroke()
        line.stroke()
    }

    /// Classic battery glyph with a proportional fill, the charge knocked out of the
    /// fill, and a bolt while charging.
    private static func drawBattery(level: Double, charging: Bool, in rect: NSRect) {
        let body = NSRect(x: rect.minX + 0.5, y: rect.midY - 5.5,
                          width: rect.width - 4, height: 11)
        let outline = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
        outline.lineWidth = 1.2
        NSColor.labelColor.withAlphaComponent(0.75).setStroke()
        outline.stroke()

        let nub = NSRect(x: body.maxX + 1, y: body.midY - 2, width: 2, height: 4)
        NSColor.labelColor.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: nub, xRadius: 1, yRadius: 1).fill()

        // Proportional fill; red when critically low.
        let inset = body.insetBy(dx: 1.8, dy: 1.8)
        let clamped = min(max(level, 0), 1)
        let fillRect = NSRect(x: inset.minX, y: inset.minY,
                              width: inset.width * CGFloat(clamped), height: inset.height)
        (clamped <= 0.2 && !charging
            ? NSColor.systemRed : NSColor.labelColor.withAlphaComponent(0.9)).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()

        drawBatteryCharge(percent: Int((clamped * 100).rounded()), in: body, over: fillRect)

        if charging {
            let bolt = "⚡" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
            let size = bolt.size(withAttributes: attrs)
            // The bolt sits off the label rather than over it.
            bolt.draw(at: NSPoint(x: body.maxX - size.width - 1, y: body.midY - size.height / 2),
                      withAttributes: attrs)
        }
    }

    /// Draws the charge the way macOS does: solid where the body is empty, and
    /// knocked out of the fill where it is not. A single colour cannot work, since
    /// the digits straddle the filled/empty boundary as the charge changes; cutting
    /// them out of the fill keeps the same contrast at every level and appearance.
    private static func drawBatteryCharge(percent: Int, in body: NSRect, over fillRect: NSRect) {
        let text = "\(percent)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: batteryLabelFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2)
        guard let context = NSGraphicsContext.current else { return }

        context.saveGraphicsState()
        let empty = NSBezierPath(rect: body)
        empty.append(NSBezierPath(rect: fillRect))
        empty.windingRule = .evenOdd
        empty.setClip()
        text.draw(at: origin, withAttributes: attributes)
        context.restoreGraphicsState()

        context.saveGraphicsState()
        NSBezierPath(rect: fillRect).setClip()
        context.compositingOperation = .destinationOut
        text.draw(at: origin, withAttributes: attributes)
        context.restoreGraphicsState()
    }
}
