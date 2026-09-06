import SwiftUI

/// Every number here was measured off the reference screenshot, which is
/// 1266 x 712 pixels. Geometry is expressed in those reference pixels and
/// scaled once, so the layout stays proportionally identical at any panel size
/// and each constant can be checked against the original image.
enum Ref {
    static let width: CGFloat = 1266
    static let height: CGFloat = 712

    /// Left and right margin shared by the pill and the diagram.
    static let hPadding: CGFloat = 50.5
    static var contentWidth: CGFloat { width - hPadding * 2 }   // 1165

    // MARK: battery pill
    static let pillTop: CGFloat = 33
    static let pillHeight: CGFloat = 77
    /// Inset of the "79%" label from the left end of the pill.
    static let pillTextInset: CGFloat = 39
    static let pillFontSize: CGFloat = 39.2     // 29px digit height
    /// The reference sizes each status glyph independently rather than setting
    /// one font size for the row: the plug reads large, the pause small.
    static let pillPlugSize: CGFloat = 50.3     // 30 x 56 drawn
    /// The reference's pause is chunkier than SF Symbols' `pause.fill`:
    /// two 10-wide bars, 30 tall, separated by 10. Drawn directly.
    static let pauseBarWidth: CGFloat = 10
    static let pauseBarHeight: CGFloat = 30
    static let pauseBarGap: CGFloat = 10
    static let pauseBarRadius: CGFloat = 3
    static let pillBoltSize: CGFloat = 37.7
    static let pillPlaneSize: CGFloat = 45      // 39 x 40 drawn
    /// Leading space before the pause group and before the plane.
    static let pillPauseLead: CGFloat = -2
    static let pillPlaneLead: CGFloat = 22
    /// Width of the dashed "resume charging" marker and its dash pattern.
    static let dashWidth: CGFloat = 6
    static let dashOn: CGFloat = 10
    static let dashOff: CGFloat = 15
    /// The charge-target handle, which overhangs the pill top and bottom.
    static let thumbWidth: CGFloat = 15
    static let thumbHeight: CGFloat = 106

    // MARK: sankey
    static let diagramTop: CGFloat = 194
    static let diagramBottom: CGFloat = 668
    static var diagramHeight: CGFloat { diagramBottom - diagramTop }   // 474
    static let nodeWidth: CGFloat = 155
    static let nodeGutter: CGFloat = 20
    static let nodePadding: CGFloat = 93
    static let nodeRadius: CGFloat = 64
    static let labelFontSize: CGFloat = 40.5    // 30px digit height
    /// SwiftUI centres text on its line box, which includes descender space no
    /// digit uses, so numerals land slightly high. These nudge them back onto
    /// the optical centre the reference uses.
    static let pillTextNudge: CGFloat = 2
    static let labelNudge: CGFloat = 3
    static let systemBlockNudge: CGFloat = 3.5

    /// Node glyph metrics, measured from the reference.
    static let plugGlyph: CGFloat = 40.3        // 28 x 45 drawn
    static let batteryGlyph: CGFloat = 41       // 59 x 27 drawn
    static let laptopGlyph: CGFloat = 40.2      // 56 x 32 drawn
    /// Space between the laptop glyph and the wattage under it.
    static let systemLabelGap: CGFloat = 17

    // MARK: runtime estimate + per-app draw
    //
    // Not in the reference screenshot. Proportions were chosen to sit in the
    // same idiom: the same surface grey, the same generous corner radius, and
    // the ivory accent reserved for the numbers that matter.

    /// Gap between the diagram and the runtime card.
    static let runtimeGap: CGFloat = 62
    static let runtimeHeight: CGFloat = 112
    static let runtimeGlyph: CGFloat = 46
    static let runtimeFontSize: CGFloat = 44
    static let runtimeCaptionSize: CGFloat = 30
    static let runtimeInset: CGFloat = 34

    /// Gap between the runtime card and the section heading.
    static let sectionGap: CGFloat = 44
    static let sectionFontSize: CGFloat = 26
    static let sectionTracking: CGFloat = 3
    /// Gap between the heading and the first row.
    static let sectionRowGap: CGFloat = 20

    static let rowHeight: CGFloat = 84
    static let rowGap: CGFloat = 16
    static let rowInset: CGFloat = 26
    static let rowIcon: CGFloat = 52
    static let rowIconGap: CGFloat = 20
    static let rowFontSize: CGFloat = 34
    /// How many application rows to show before the system remainder.
    static let appRowCount = 4

    /// Panel height once the new sections are stacked below the diagram.
    static var extendedHeight: CGFloat {
        diagramBottom + runtimeGap + runtimeHeight + sectionGap + sectionFontSize
            + sectionRowGap
            + CGFloat(appRowCount + 1) * rowHeight + CGFloat(appRowCount) * rowGap
            + (height - diagramBottom)
    }

}

/// Colours sampled directly from the reference screenshot.
enum Palette {
    /// Unfilled part of the battery pill.
    static let pillTrack = Color(red: 68 / 255, green: 67 / 255, blue: 72 / 255)
    /// Charge fill.
    static let pillFill = Color(red: 22 / 255, green: 112 / 255, blue: 212 / 255)
    /// Node cards and ribbons share one flat grey.
    static let surface = Color(red: 66 / 255, green: 65 / 255, blue: 70 / 255)
    /// Wattage labels.
    static let label = Color.white.opacity(0.92)
    /// Warm ivory used for the adapter glyph.
    static let energy = Color(red: 242 / 255, green: 229 / 255, blue: 185 / 255)
    /// The battery's charge bar is a softer, less saturated warm grey than the
    /// plug, with a near-white case around it.
    static let batteryFill = Color(red: 198 / 255, green: 188 / 255, blue: 176 / 255)
    static let batteryCase = Color(red: 233 / 255, green: 233 / 255, blue: 235 / 255)
    /// Handle and dashed marker on the pill.
    static let marker = Color.white.opacity(0.55)
    static let laptopBody = Color.white.opacity(0.75)
    static let laptopScreen = Color.white.opacity(0.26)
    /// Secondary text: section headings and captions.
    static let muted = Color.white.opacity(0.45)
    /// The proportional share bar inside an app row.
    static let rowBar = Color.white.opacity(0.11)
}

/// Converts reference pixels to points for a given panel width.
struct Scale {
    let factor: CGFloat
    init(panelWidth: CGFloat) { factor = panelWidth / Ref.width }
    /// Scale a single measurement.
    func callAsFunction(_ px: CGFloat) -> CGFloat { px * factor }
    var panelHeight: CGFloat { Ref.height * factor }
    /// Height once the runtime and per-app sections are included.
    var extendedPanelHeight: CGFloat { Ref.extendedHeight * factor }
}
