import Foundation
import IOKit

/// Reads live power telemetry out of the `AppleSmartBattery` IORegistry node.
///
/// Apple Silicon Macs publish a `PowerTelemetryData` dictionary there with
/// milliwatt-resolution figures for the wall input, the battery and the system
/// load. Those three are what this app draws. Intel Macs (and any Mac where the
/// dictionary is missing) fall back to `Voltage x Amperage` plus the coarser
/// `BatteryData` figures, so the app still works, just with less precision.
public struct SmartBatteryReader {
    public init() {}

    /// All properties of the `AppleSmartBattery` service, or nil if absent
    /// (desktop Macs, or a very unusual failure).
    public static func rawProperties() -> [String: Any]? {
        let match = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dict
    }

    /// Current power state, or nil on a machine with no battery.
    public func read() -> PowerSnapshot? {
        guard let props = Self.rawProperties() else { return nil }
        return Self.snapshot(from: props)
    }

    /// Pure translation from IORegistry properties to a snapshot — separated
    /// from the IOKit call so it can be tested against captured fixtures.
    /// - Parameters:
    ///   - smc: live wattages, when the SMC sensors are available. They take
    ///     precedence over the IORegistry figures, which lag by up to a minute.
    ///   - source: charge state from IOPowerSources, which reacts to a cable
    ///     being moved immediately.
    public static func snapshot(
        from props: [String: Any],
        smc: SMCPower? = nil,
        source: PowerSourceState? = nil
    ) -> PowerSnapshot {
        let telemetry = props["PowerTelemetryData"] as? [String: Any] ?? [:]
        let batteryData = props["BatteryData"] as? [String: Any] ?? [:]

        let external = source?.externalConnected ?? (props["ExternalConnected"] as? Bool ?? false)
        let charging = source?.isCharging ?? (props["IsCharging"] as? Bool ?? false)
        let fullyCharged = props["FullyCharged"] as? Bool ?? false

        // Percentage: prefer the raw pair, which is what the system menu shows.
        let current = double(props["CurrentCapacity"]) ?? 0
        let maxCap = double(props["MaxCapacity"]) ?? 100
        var percent = maxCap > 0 ? (current / maxCap) * 100 : 0
        // On Apple Silicon CurrentCapacity is already a percentage.
        if maxCap == 100 { percent = current }
        percent = min(100, max(0, percent))
        if let source { percent = source.percent }

        // --- the three flows, in watts -------------------------------------
        // Wall -> system, after adapter conversion loss.
        var adapter = milliwatts(telemetry["SystemPowerIn"])
            ?? double(batteryData["AdapterPower"])
            ?? 0

        // Battery power, positive into the battery. Falls back to pack
        // voltage x pack current, where Amperage is already negative while
        // discharging, matching our sign convention.
        let packPower: Double? = {
            guard let mv = double(props["Voltage"]),
                  let ma = double(props["Amperage"]) else { return nil }
            return (mv / 1000) * (ma / 1000)
        }()
        var battery: Double = milliwatts(telemetry["BatteryPower"]) ?? packPower ?? 0

        // What the machine consumes.
        var load: Double = milliwatts(telemetry["SystemLoad"]) ?? (adapter - battery)

        // Live SMC sensors win. The battery figure is derived from the other
        // two so the three always balance exactly.
        if let smc {
            adapter = smc.adapter
            battery = smc.battery
            load = adapter - battery
        }

        if !external {
            // Unplugged: the pack is the only source, so the load is exactly
            // what the battery is giving up. Some firmware keeps reporting a
            // stale non-zero adapter figure for a tick after the cable goes,
            // which must not be allowed to inflate the load.
            adapter = 0
            if battery > 0 { battery = -battery }
            let discharge = -battery
            load = discharge > 0 ? discharge : max(0, load)
            battery = -load
        } else {
            // Keep the three numbers self-consistent even when the firmware
            // samples them a few milliseconds apart.
            let implied = adapter - battery
            if abs(implied - load) > 0.5 { load = implied }
        }

        // Charging is "paused" when we are on AC, not charging, and the pack is
        // not simply full — a charge limit, thermal hold or optimised charging.
        let notChargingReason = int(
            (props["ChargerData"] as? [String: Any])?["NotChargingReason"]
        ) ?? 0
        let paused = external && !charging && (notChargingReason != 0 || battery < 0) && !fullyCharged

        // --- adapter identity ----------------------------------------------
        let adapterDetails = props["AdapterDetails"] as? [String: Any]
        let adapterWatts = int(adapterDetails?["Watts"])
        let adapterName = adapterDetails?["Name"] as? String

        // --- health / vitals -------------------------------------------------
        var health: Double?
        if let nominal = double(props["NominalChargeCapacity"]),
           let design = double(props["DesignCapacity"]), design > 0 {
            health = (nominal / design) * 100
        } else if let raw = double(props["AppleRawMaxCapacity"]),
                  let design = double(props["DesignCapacity"]), design > 0 {
            health = (raw / design) * 100
        }

        var temperature: Double?
        if let t = double(props["Temperature"]) { temperature = t / 100 }

        var remaining: Int? = source?.timeRemaining
        if remaining == nil, let t = int(props["TimeRemaining"]), t > 0, t != 65535 { remaining = t }

        // Pack energy. Capacity is in mAh, so it needs a voltage to become
        // watt-hours - and the *nominal* voltage, not the instantaneous one:
        // a full pack reads near 13.2 V but averages about 3.8 V per cell over
        // a discharge, and using the full-charge figure overstates runtime by
        // roughly 15%.
        let cells = ((props["BatteryData"] as? [String: Any])?["CellVoltage"] as? [Any])?.count ?? 3
        let nominalVolts = Double(max(1, cells)) * 3.8
        let remainingMah = double(props["AppleRawCurrentCapacity"])
        let fullMah = double(props["NominalChargeCapacity"]) ?? double(props["AppleRawMaxCapacity"])
        let remainingWh = remainingMah.map { $0 / 1000 * nominalVolts }
        let fullWh = fullMah.map { $0 / 1000 * nominalVolts }

        return PowerSnapshot(
            percent: percent,
            externalConnected: external,
            isCharging: charging,
            fullyCharged: fullyCharged,
            chargingPaused: paused,
            adapterPower: max(0, adapter),
            batteryPower: battery,
            systemLoad: max(0, load),
            adapterWatts: adapterWatts,
            adapterName: adapterName,
            health: health,
            cycleCount: int(props["CycleCount"]),
            temperature: temperature,
            timeRemaining: remaining,
            remainingWh: remainingWh,
            fullWh: fullWh
        )
    }

    // MARK: - number coercion

    private static func double(_ any: Any?) -> Double? {
        switch any {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        default: return nil
        }
    }

    private static func int(_ any: Any?) -> Int? {
        switch any {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        default: return nil
        }
    }

    /// Telemetry values are milliwatts as integers; convert to watts.
    private static func milliwatts(_ any: Any?) -> Double? {
        guard let v = double(any) else { return nil }
        return v / 1000
    }
}
