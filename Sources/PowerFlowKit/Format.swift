import Foundation

/// Number formatting, matched to the reference: ribbons carry two decimals
/// and a space, the machine's card carries a truncated integer and no space.
public enum Format {
    /// Ribbons carry two decimals and a thin gap: "87.77 W".
    public static func ribbonWatts(_ w: Double) -> String {
        String(format: "%.2f W", w)
    }

    /// The machine's card carries a truncated whole number and no gap, so a
    /// 104.69 W load reads "104W" exactly as the reference does.
    /// App rows are finer grained than the diagram: sub-watt draws are common,
    /// so they keep a decimal until they are large.
    public static func appWatts(_ w: Double) -> String {
        w >= 10 ? String(format: "%.0f W", w) : String(format: "%.1f W", w)
    }

    public static func nodeWatts(_ w: Double) -> String {
        String(format: "%.0fW", floor(w))
    }
}
