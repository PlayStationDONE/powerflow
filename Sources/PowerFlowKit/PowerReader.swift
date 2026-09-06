import Foundation
import IOKit.ps

/// The two live wattages read from the SMC. The battery figure is derived from
/// them rather than read separately, so the diagram always balances: three
/// independently sampled sensors would not sum exactly, and a Sankey whose
/// ribbons do not add up to its node is simply wrong.
public struct SMCPower: Equatable, Sendable {
    /// `PDTR` - power coming in from the adapter, in watts.
    public var adapter: Double
    /// Battery power in watts, positive into the pack, computed from the
    /// signed pack current `B0AC` and the pack voltage `B0AV`. This is the same
    /// sensor pair the IORegistry reports as Amperage and Voltage, so it uses
    /// the same sign convention, but it updates every second instead of every
    /// minute.
    public var battery: Double

    public init(adapter: Double, battery: Double) {
        self.adapter = adapter
        self.battery = battery
    }
}

/// Charge state from IOPowerSources, which updates the moment a cable moves,
/// unlike the IORegistry battery entry.
public struct PowerSourceState: Equatable, Sendable {
    public var percent: Double
    public var externalConnected: Bool
    public var isCharging: Bool
    public var timeRemaining: Int?

    public init(percent: Double, externalConnected: Bool, isCharging: Bool, timeRemaining: Int?) {
        self.percent = percent
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.timeRemaining = timeRemaining
    }
}

/// Composes the three sources into one snapshot:
///
///   * SMC              - live wattages, about once a second
///   * IOPowerSources   - charge level and cable state, event driven
///   * AppleSmartBattery - health, cycles, temperature, adapter identity,
///                         which change slowly enough that its ~60 s
///                         refresh does not matter
public final class PowerReader {
    private var smc: SMCReader?
    /// Consecutive failed SMC reads. A couple can happen around sleep; a run of
    /// them means the connection is stale and needs replacing.
    private var failures = 0
    private let failuresBeforeReconnect = 3

    public init() {
        smc = SMCReader()
    }

    /// Called when the machine wakes: the user client is often unusable by then.
    public func handleWake() {
        if smc?.reconnect() != true { smc = SMCReader() }
        failures = 0
    }

    /// True when live SMC wattages are available; otherwise the app falls back
    /// to the slower figures published by AppleSmartBattery.
    public var hasLivePower: Bool { smc != nil }

    public func read() -> PowerSnapshot? {
        guard let props = SmartBatteryReader.rawProperties() else { return nil }
        return SmartBatteryReader.snapshot(
            from: props,
            smc: readSMC(),
            source: Self.readPowerSources()
        )
    }

    /// Reads the adapter input and the battery's own current. The system load
    /// is deliberately *not* read as a third sensor: `PDTR` and `PSTR` are
    /// sampled on different schedules and differ by several watts moment to
    /// moment, which would leave the diagram's ribbons not adding up. Deriving
    /// the load from the other two keeps it exact.
    ///
    /// Returns nil when the sensors are missing or implausible, so a Mac
    /// without them falls back to the IORegistry figures.
    public func readSMC() -> SMCPower? {
        guard let smc,
              let adapter = smc.double("PDTR"),
              let milliamps = smc.double("B0AC"),
              let millivolts = smc.double("B0AV"),
              adapter.isFinite, adapter >= 0, adapter < 500,
              millivolts > 1000, millivolts < 30000,
              abs(milliamps) < 20000
        else {
            failures += 1
            if failures >= failuresBeforeReconnect {
                failures = 0
                if self.smc?.reconnect() != true { self.smc = SMCReader() }
            }
            return nil
        }
        failures = 0
        return SMCPower(adapter: adapter, battery: millivolts / 1000 * milliamps / 1000)
    }

    public static func readPowerSources() -> PowerSourceState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            let current = (d[kIOPSCurrentCapacityKey] as? Double) ?? 0
            let max = (d[kIOPSMaxCapacityKey] as? Double) ?? 100
            let state = d[kIOPSPowerSourceStateKey] as? String
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            var remaining: Int?
            if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0 { remaining = t }
            if charging, let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0 { remaining = t }

            return PowerSourceState(
                percent: max > 0 ? min(100, max2(current / max * 100)) : 0,
                externalConnected: state == kIOPSACPowerValue,
                isCharging: charging,
                timeRemaining: remaining
            )
        }
        return nil
    }

    private static func max2(_ v: Double) -> Double { Swift.max(0, v) }
}
