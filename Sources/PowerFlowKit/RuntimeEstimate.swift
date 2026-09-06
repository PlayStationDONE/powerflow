import Foundation

/// How long the battery would last at a given draw.
public enum RuntimeEstimate {

    /// Seconds of runtime left, or nil when it cannot be known.
    ///
    /// The load is the machine's own consumption, which excludes any power
    /// going into charging the pack, so the answer is the same question whether
    /// or not a cable is currently attached: *if I unplugged right now, how
    /// long would this last?*
    public static func seconds(remainingWh: Double?, load: Double) -> Double? {
        guard let remainingWh, remainingWh > 0, load > 0.5 else { return nil }
        return remainingWh / load * 3600
    }

    /// "2h 18m", or "47m" under an hour.
    public static func format(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours >= 100 { return "99h+" }
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// A rolling mean of the system load.
///
/// Load swings by tens of watts between samples, and an estimate computed from
/// an instantaneous reading jumps between one hour and five. Averaging over a
/// window makes the number stable enough to act on.
public struct LoadAverager {
    private var samples: [Double] = []
    private let capacity: Int

    public init(window: Int = 60) {
        capacity = max(1, window)
    }

    public mutating func add(_ watts: Double) {
        guard watts.isFinite, watts >= 0 else { return }
        samples.append(watts)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// Nil until there is at least one sample.
    public var average: Double? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    public var count: Int { samples.count }
}
