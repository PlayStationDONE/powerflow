import Foundation

/// Rejects readings that cannot be true.
///
/// Sensors occasionally drop a sample. On its own that is harmless, but the
/// diagram's whole shape depends on which way the battery is flowing: one
/// spurious zero from the adapter makes the panel redraw as though the cable
/// had been pulled out, then snap back a moment later. Holding the previous
/// value for one tick is far closer to the truth than believing the glitch.
public enum SampleGuard {

    /// Returns `fresh`, with implausible values replaced by the previous ones.
    public static func reconcile(_ fresh: PowerSnapshot, previous: PowerSnapshot?) -> PowerSnapshot {
        var out = fresh
        guard let previous else { return out }

        // An attached adapter always delivers something.
        if out.externalConnected, out.adapterPower <= 0.01, previous.adapterPower > 0.01 {
            out.adapterPower = previous.adapterPower
            out.batteryPower = previous.batteryPower
            out.systemLoad = previous.systemLoad
        }

        // A running machine always consumes something.
        if out.systemLoad <= 0.01, previous.systemLoad > 0.01 {
            out.systemLoad = previous.systemLoad
            out.adapterPower = previous.adapterPower
            out.batteryPower = previous.batteryPower
        }

        return out
    }
}
