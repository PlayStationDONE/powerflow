import Foundation

/// One instant of the machine's power state.
///
/// The three power figures obey conservation of energy:
///
///     adapterPower - batteryPower == systemLoad
///
/// `batteryPower` is signed the way the hardware reports it: **positive means
/// power flowing *into* the battery** (charging), negative means the battery is
/// supplying the machine (discharging). So a laptop drawing more than its
/// adapter can supply has a negative `batteryPower` and a `systemLoad` larger
/// than `adapterPower` — the case the Sankey draws as two ribbons converging.
public struct PowerSnapshot: Equatable, Sendable {
    /// Charge level, 0...100.
    public var percent: Double
    /// A power adapter is physically attached.
    public var externalConnected: Bool
    /// The battery is actively taking charge.
    public var isCharging: Bool
    /// The battery is at its charging target.
    public var fullyCharged: Bool
    /// Charging is being withheld while on AC (macOS charge limit, thermal hold,
    /// optimized charging...). Drives the "paused" glyph.
    public var chargingPaused: Bool

    /// Watts arriving from the wall, after adapter conversion losses.
    public var adapterPower: Double
    /// Watts into (+) or out of (-) the battery.
    public var batteryPower: Double
    /// Watts the machine is actually consuming.
    public var systemLoad: Double

    /// Rated output of the attached adapter, e.g. 96.
    public var adapterWatts: Int?
    /// Marketing name of the attached adapter.
    public var adapterName: String?

    /// Battery health as a percentage of design capacity.
    public var health: Double?
    public var cycleCount: Int?
    /// Cell temperature in degrees Celsius.
    public var temperature: Double?
    /// Minutes until empty (discharging) or full (charging); nil when unknown.
    public var timeRemaining: Int?

    /// Energy left in the pack, in watt-hours.
    public var remainingWh: Double?
    /// Energy the pack holds when full, in watt-hours.
    public var fullWh: Double?

    /// Independent whole-system figure from SMC `PSTR`, when present. Shown only
    /// as a cross-check against `systemLoad`, which is derived.
    public var smcSystemTotal: Double?
    /// Which source the three flow figures came from.
    public var dataSource: PowerDataSource

    public init(
        percent: Double = 0,
        externalConnected: Bool = false,
        isCharging: Bool = false,
        fullyCharged: Bool = false,
        chargingPaused: Bool = false,
        adapterPower: Double = 0,
        batteryPower: Double = 0,
        systemLoad: Double = 0,
        adapterWatts: Int? = nil,
        adapterName: String? = nil,
        health: Double? = nil,
        cycleCount: Int? = nil,
        temperature: Double? = nil,
        timeRemaining: Int? = nil,
        remainingWh: Double? = nil,
        fullWh: Double? = nil,
        smcSystemTotal: Double? = nil,
        dataSource: PowerDataSource = .registry
    ) {
        self.percent = percent
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.fullyCharged = fullyCharged
        self.chargingPaused = chargingPaused
        self.adapterPower = adapterPower
        self.batteryPower = batteryPower
        self.systemLoad = systemLoad
        self.adapterWatts = adapterWatts
        self.adapterName = adapterName
        self.health = health
        self.cycleCount = cycleCount
        self.temperature = temperature
        self.timeRemaining = timeRemaining
        self.remainingWh = remainingWh
        self.fullWh = fullWh
        self.smcSystemTotal = smcSystemTotal
        self.dataSource = dataSource
    }

    /// Watts leaving the battery (0 while charging).
    public var batteryOutput: Double { max(0, -batteryPower) }
    /// Watts entering the battery (0 while discharging).
    public var batteryInput: Double { max(0, batteryPower) }

    /// The state of the reference screenshot: a 104 W load that a 96 W-class
    /// adapter cannot cover alone, so the battery makes up the difference.
    public static let sample = PowerSnapshot(
        percent: 79,
        externalConnected: true,
        isCharging: false,
        fullyCharged: false,
        chargingPaused: true,
        adapterPower: 87.77,
        batteryPower: -16.92,
        systemLoad: 104.69,
        adapterWatts: 96,
        adapterName: "96W USB-C Power Adapter",
        health: 96,
        cycleCount: 23,
        temperature: 29.8,
        timeRemaining: nil,
        remainingWh: 55.4,
        fullWh: 70.1
    )

    /// On AC with the pack filling: the wall feeds the machine and the battery.
    public static let charging = PowerSnapshot(
        percent: 42, externalConnected: true, isCharging: true,
        adapterPower: 61.40, batteryPower: 26.15, systemLoad: 35.25,
        adapterWatts: 96, adapterName: "96W USB-C Power Adapter",
        remainingWh: 29.4, fullWh: 70.1
    )

    /// Unplugged: one source, one sink, one full-height ribbon.
    public static let onBattery = PowerSnapshot(
        percent: 63, externalConnected: false,
        adapterPower: 0, batteryPower: -14.32, systemLoad: 14.32,
        remainingWh: 44.2, fullWh: 70.1
    )

    /// On AC, pack full: a single adapter-to-machine ribbon.
    public static let full = PowerSnapshot(
        percent: 100, externalConnected: true, fullyCharged: true,
        adapterPower: 19.04, batteryPower: 0, systemLoad: 19.04,
        adapterWatts: 96, adapterName: "96W USB-C Power Adapter",
        remainingWh: 70.1, fullWh: 70.1
    )
}
