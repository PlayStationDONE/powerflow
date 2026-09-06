import XCTest
@testable import PowerFlowKit

/// Fixtures mirror the shape of a real `AppleSmartBattery` entry on Apple
/// Silicon, captured from `ioreg -arn AppleSmartBattery`.
private func props(
    telemetry: [String: Any]? = nil,
    external: Bool = true,
    charging: Bool = false,
    fullyCharged: Bool = false,
    current: Int = 79,
    maxCap: Int = 100,
    voltage: Int = 13228,
    amperage: Int = 0,
    notChargingReason: Int = 0
) -> [String: Any] {
    var d: [String: Any] = [
        "ExternalConnected": external,
        "IsCharging": charging,
        "FullyCharged": fullyCharged,
        "CurrentCapacity": current,
        "MaxCapacity": maxCap,
        "Voltage": voltage,
        "Amperage": amperage,
        "DesignCapacity": 6249,
        "NominalChargeCapacity": 6055,
        "CycleCount": 23,
        "Temperature": 2982,
        "TimeRemaining": 65535,
        "AdapterDetails": ["Watts": 94, "Name": "96W USB-C Power Adapter"],
        "ChargerData": ["NotChargingReason": notChargingReason],
    ]
    if let telemetry { d["PowerTelemetryData"] = telemetry }
    return d
}

final class SmartBatteryReaderTests: XCTestCase {

    /// The reference screenshot's state: a load bigger than the adapter can
    /// cover, with the battery making up the difference.
    func testDischargingOnACMatchesReference() {
        let s = SmartBatteryReader.snapshot(from: props(
            telemetry: [
                "SystemPowerIn": 87770,
                "BatteryPower": -16920,
                "SystemLoad": 104690,
            ],
            notChargingReason: 4194305
        ))
        XCTAssertEqual(s.adapterPower, 87.77, accuracy: 0.001)
        XCTAssertEqual(s.batteryPower, -16.92, accuracy: 0.001)
        XCTAssertEqual(s.systemLoad, 104.69, accuracy: 0.001)
        XCTAssertEqual(s.batteryOutput, 16.92, accuracy: 0.001)
        XCTAssertEqual(s.batteryInput, 0)
        XCTAssertTrue(s.chargingPaused)
        XCTAssertEqual(s.percent, 79)
    }

    /// Conservation of energy is the invariant the whole diagram rests on.
    func testFlowsBalance() {
        let s = SmartBatteryReader.snapshot(from: props(
            telemetry: ["SystemPowerIn": 87770, "BatteryPower": -16920, "SystemLoad": 104690]
        ))
        XCTAssertEqual(s.adapterPower - s.batteryPower, s.systemLoad, accuracy: 0.01)
    }

    /// When the firmware samples the three figures a moment apart they can
    /// disagree; the load is recomputed so the ribbons still add up.
    func testInconsistentSamplesAreReconciled() {
        let s = SmartBatteryReader.snapshot(from: props(
            telemetry: ["SystemPowerIn": 90000, "BatteryPower": -10000, "SystemLoad": 70000]
        ))
        XCTAssertEqual(s.systemLoad, 100, accuracy: 0.01)
        XCTAssertEqual(s.adapterPower - s.batteryPower, s.systemLoad, accuracy: 0.01)
    }

    func testChargingHasPositiveBatteryPower() {
        let s = SmartBatteryReader.snapshot(from: props(
            telemetry: ["SystemPowerIn": 60000, "BatteryPower": 25000, "SystemLoad": 35000],
            charging: true
        ))
        XCTAssertEqual(s.batteryInput, 25, accuracy: 0.001)
        XCTAssertEqual(s.batteryOutput, 0)
        XCTAssertFalse(s.chargingPaused, "charging is not paused")
    }

    /// Unplugged, the adapter node must vanish and the battery must cover the
    /// whole load, even if the firmware still reports a stale adapter figure.
    func testUnpluggedZeroesTheAdapter() {
        let s = SmartBatteryReader.snapshot(from: props(
            telemetry: ["SystemPowerIn": 12000, "BatteryPower": -14500, "SystemLoad": 14500],
            external: false
        ))
        XCTAssertEqual(s.adapterPower, 0)
        XCTAssertEqual(s.batteryOutput, 14.5, accuracy: 0.001)
        XCTAssertEqual(s.systemLoad, 14.5, accuracy: 0.001)
        XCTAssertFalse(s.chargingPaused)
    }

    /// Intel Macs and any machine without PowerTelemetryData fall back to
    /// pack voltage x pack current, where a negative amperage is a discharge.
    func testFallsBackToVoltageTimesAmperage() {
        let s = SmartBatteryReader.snapshot(from: props(
            telemetry: nil, amperage: -2000
        ))
        // 13.228 V x -2.0 A = -26.456 W
        XCTAssertEqual(s.batteryPower, -26.456, accuracy: 0.01)
    }

    func testFullyChargedIsNotReportedAsPaused() {
        let s = SmartBatteryReader.snapshot(from: props(
            telemetry: ["SystemPowerIn": 19000, "BatteryPower": 0, "SystemLoad": 19000],
            fullyCharged: true, current: 100, notChargingReason: 4194305
        ))
        XCTAssertFalse(s.chargingPaused)
        XCTAssertEqual(s.percent, 100)
    }

    func testHealthAndVitals() {
        let s = SmartBatteryReader.snapshot(from: props(telemetry: ["SystemPowerIn": 0, "BatteryPower": 0, "SystemLoad": 0]))
        XCTAssertEqual(s.health ?? 0, 6055.0 / 6249.0 * 100, accuracy: 0.01)
        XCTAssertEqual(s.cycleCount, 23)
        XCTAssertEqual(s.temperature ?? 0, 29.82, accuracy: 0.01)
        XCTAssertNil(s.timeRemaining, "65535 means unknown")
        XCTAssertEqual(s.adapterWatts, 94)
    }

    func testPercentIsClamped() {
        let s = SmartBatteryReader.snapshot(from: props(current: 120))
        XCTAssertEqual(s.percent, 100)
    }
}

final class FormatTests: XCTestCase {
    /// The reference shows 104.69 W as "104W" on the machine's card, so it
    /// truncates rather than rounding.
    func testNodeWattsTruncates() {
        XCTAssertEqual(Format.nodeWatts(104.69), "104W")
        XCTAssertEqual(Format.nodeWatts(19.0), "19W")
    }

    func testRibbonWattsUsesTwoDecimals() {
        XCTAssertEqual(Format.ribbonWatts(87.77), "87.77 W")
        XCTAssertEqual(Format.ribbonWatts(16.9), "16.90 W")
    }
}

/// The SMC path is what the app actually runs on: `AppleSmartBattery`
/// republishes only about once a minute, which is far too slow for a live
/// diagram, so the wattages come from sensors that update every second.
final class SMCSourceTests: XCTestCase {

    /// SMC figures must win over the stale IORegistry ones.
    func testSMCOverridesStaleRegistryValues() {
        let s = SmartBatteryReader.snapshot(
            from: props(telemetry: ["SystemPowerIn": 1516, "BatteryPower": 0, "SystemLoad": 1516]),
            smc: SMCPower(adapter: 38.47, battery: 0)
        )
        XCTAssertEqual(s.adapterPower, 38.47, accuracy: 0.001)
        XCTAssertEqual(s.systemLoad, 38.47, accuracy: 0.001)
    }

    /// The load is derived, never read as a third sensor, so the ribbons
    /// always add up to the node they feed.
    func testDerivedLoadAlwaysBalances() {
        for battery in [-25.0, -0.4, 0.0, 12.5, 40.0] {
            let s = SmartBatteryReader.snapshot(
                from: props(),
                smc: SMCPower(adapter: 60, battery: battery)
            )
            XCTAssertEqual(s.adapterPower - s.batteryPower, s.systemLoad, accuracy: 1e-9)
        }
    }

    /// Discharging on AC is the reference screenshot's state: the machine
    /// outruns the adapter and the pack covers the shortfall.
    func testDischargingOnACViaSMC() {
        let s = SmartBatteryReader.snapshot(
            from: props(),
            smc: SMCPower(adapter: 87.77, battery: -16.92)
        )
        XCTAssertEqual(s.systemLoad, 104.69, accuracy: 0.001)
        XCTAssertEqual(s.batteryOutput, 16.92, accuracy: 0.001)
    }

    /// Unplugged, the adapter node disappears and the pack carries the load,
    /// whatever the adapter sensor happens to be reporting.
    func testUnpluggedViaSMC() {
        let s = SmartBatteryReader.snapshot(
            from: props(external: false),
            smc: SMCPower(adapter: 3.0, battery: -14.32),
            source: PowerSourceState(percent: 63, externalConnected: false, isCharging: false, timeRemaining: 240)
        )
        XCTAssertEqual(s.adapterPower, 0)
        XCTAssertEqual(s.systemLoad, 14.32, accuracy: 0.001)
        XCTAssertEqual(s.percent, 63)
        XCTAssertEqual(s.timeRemaining, 240)
    }

    /// IOPowerSources reacts to a cable the moment it moves; the IORegistry
    /// copy can be a minute behind, so the fast source must win.
    func testPowerSourceStateOverridesRegistry() {
        let s = SmartBatteryReader.snapshot(
            from: props(external: true, charging: false, current: 100),
            source: PowerSourceState(percent: 41, externalConnected: false, isCharging: false, timeRemaining: nil)
        )
        XCTAssertFalse(s.externalConnected)
        XCTAssertEqual(s.percent, 41)
    }
}
