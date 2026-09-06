import XCTest
@testable import PowerFlowKit

private func sample(_ pid: Int32, _ ppid: Int32, _ name: String, _ nj: UInt64) -> ProcessSample {
    ProcessSample(pid: pid, ppid: ppid, name: name, energyNanojoules: nj)
}

private func index(_ s: [ProcessSample]) -> [Int32: ProcessSample] {
    Dictionary(uniqueKeysWithValues: s.map { ($0.pid, $0) })
}

final class AppPowerAggregatorTests: XCTestCase {

    /// A joule per second is a watt; the interval must actually divide.
    func testWattsAreEnergyOverTime() {
        let before = index([sample(10, 1, "App", 0)])
        let after = [sample(10, 1, "App", 4_000_000_000)]   // 4 J
        let rows = AppPowerAggregator.aggregate(previous: before, current: after, interval: 2)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].watts, 2.0, accuracy: 1e-9)
    }

    /// A browser's helpers must land on the browser, not bury everything else
    /// under twenty anonymous rows.
    func testHelpersFoldIntoTheOwningApp() {
        let before = index([
            sample(10, 1, "Google Chrome", 0),
            sample(11, 10, "Google Chrome Helper", 0),
            sample(12, 11, "Google Chrome Helper (Renderer)", 0),
            sample(20, 1, "Notes", 0),
        ])
        let after = [
            sample(10, 1, "Google Chrome", 1_000_000_000),
            sample(11, 10, "Google Chrome Helper", 2_000_000_000),
            sample(12, 11, "Google Chrome Helper (Renderer)", 3_000_000_000),
            sample(20, 1, "Notes", 500_000_000),
        ]
        let rows = AppPowerAggregator.aggregate(
            previous: before, current: after, interval: 1,
            appNames: [10: "Google Chrome", 20: "Notes"]
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "Google Chrome")
        // 1 + 2 + 3 joules in one second, including the grandchild.
        XCTAssertEqual(rows[0].watts, 6.0, accuracy: 1e-9)
        XCTAssertEqual(rows[1].name, "Notes")
        XCTAssertEqual(rows[1].watts, 0.5, accuracy: 1e-9)
    }

    /// Heaviest first, because only the top few are shown.
    func testSortedByWattsDescending() {
        let before = index([sample(1, 1, "A", 0), sample(2, 1, "B", 0), sample(3, 1, "C", 0)])
        let after = [
            sample(1, 1, "A", 1_000_000_000),
            sample(2, 1, "B", 9_000_000_000),
            sample(3, 1, "C", 5_000_000_000),
        ]
        let rows = AppPowerAggregator.aggregate(previous: before, current: after, interval: 1)
        XCTAssertEqual(rows.map(\.name), ["B", "C", "A"])
    }

    /// A recycled pid can present a counter lower than last time; treating that
    /// as a huge unsigned delta would invent an enormous phantom consumer.
    func testCounterGoingBackwardsIsIgnored() {
        let before = index([sample(10, 1, "App", 5_000_000_000)])
        let after = [sample(10, 1, "App", 1_000_000_000)]
        let rows = AppPowerAggregator.aggregate(previous: before, current: after, interval: 1)
        XCTAssertTrue(rows.isEmpty)
    }

    /// A process first seen in this sample has no baseline to subtract.
    func testProcessWithNoPreviousSampleIsSkipped() {
        let rows = AppPowerAggregator.aggregate(
            previous: [:], current: [sample(10, 1, "New", 9_000_000_000)], interval: 1
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testZeroIntervalProducesNothing() {
        let before = index([sample(10, 1, "App", 0)])
        let after = [sample(10, 1, "App", 1_000_000_000)]
        XCTAssertTrue(AppPowerAggregator.aggregate(previous: before, current: after, interval: 0).isEmpty)
    }

    /// A parent chain that loops must not spin forever.
    func testParentCycleTerminates() {
        let before = index([sample(10, 11, "A", 0), sample(11, 10, "B", 0)])
        let after = [sample(10, 11, "A", 1_000_000_000), sample(11, 10, "B", 1_000_000_000)]
        let rows = AppPowerAggregator.aggregate(previous: before, current: after, interval: 1)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.watts }, 2.0, accuracy: 1e-9)
    }

    /// An orphan keeps its own name rather than being attributed to something
    /// it does not belong to.
    func testUnknownProcessKeepsItsOwnName() {
        let before = index([sample(99, 1, "some-daemon", 0)])
        let after = [sample(99, 1, "some-daemon", 2_000_000_000)]
        let rows = AppPowerAggregator.aggregate(
            previous: before, current: after, interval: 1, appNames: [10: "Chrome"]
        )
        XCTAssertEqual(rows.first?.name, "some-daemon")
    }
}

final class RuntimeEstimateTests: XCTestCase {

    /// 70 Wh at 20 W is three and a half hours.
    func testSecondsFromEnergyAndLoad() {
        let s = RuntimeEstimate.seconds(remainingWh: 70, load: 20)
        XCTAssertEqual(s ?? 0, 12600, accuracy: 1)
        XCTAssertEqual(RuntimeEstimate.format(s), "3h 30m")
    }

    /// The reference screenshot's state: a 104.69 W load empties 55.4 Wh fast.
    func testHeavyLoadGivesShortRuntime() {
        let s = RuntimeEstimate.seconds(remainingWh: 55.4, load: 104.69)
        XCTAssertEqual(RuntimeEstimate.format(s), "31m")
    }

    /// A load near zero would divide out to an absurd number of hours.
    func testNegligibleLoadHasNoAnswer() {
        XCTAssertNil(RuntimeEstimate.seconds(remainingWh: 70, load: 0))
        XCTAssertNil(RuntimeEstimate.seconds(remainingWh: 70, load: 0.2))
    }

    func testEmptyOrUnknownPackHasNoAnswer() {
        XCTAssertNil(RuntimeEstimate.seconds(remainingWh: nil, load: 20))
        XCTAssertNil(RuntimeEstimate.seconds(remainingWh: 0, load: 20))
    }

    func testFormatting() {
        XCTAssertNil(RuntimeEstimate.format(nil))
        XCTAssertNil(RuntimeEstimate.format(0))
        XCTAssertEqual(RuntimeEstimate.format(59 * 60), "59m")
        XCTAssertEqual(RuntimeEstimate.format(3600), "1h 0m")
        XCTAssertEqual(RuntimeEstimate.format(400 * 3600), "99h+")
    }
}

final class LoadAveragerTests: XCTestCase {

    func testAveragesSamples() {
        var a = LoadAverager(window: 4)
        for v in [10.0, 20.0, 30.0] { a.add(v) }
        XCTAssertEqual(a.average ?? 0, 20, accuracy: 1e-9)
    }

    /// Only the window's worth of recent load counts, so the estimate follows
    /// a sustained change instead of being anchored to an old one.
    func testWindowDropsOldSamples() {
        var a = LoadAverager(window: 3)
        for v in [100.0, 100.0, 100.0, 10.0, 10.0, 10.0] { a.add(v) }
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a.average ?? 0, 10, accuracy: 1e-9)
    }

    func testNoSamplesHasNoAverage() {
        XCTAssertNil(LoadAverager().average)
    }

    func testRejectsNonsense() {
        var a = LoadAverager()
        a.add(.nan)
        a.add(-5)
        XCTAssertNil(a.average)
    }
}

final class SampleGuardTests: XCTestCase {

    /// One dropped adapter reading must not redraw the panel as though the
    /// cable had been pulled out.
    func testZeroAdapterOnACIsRejected() {
        let good = PowerSnapshot(externalConnected: true, adapterPower: 46.8,
                                 batteryPower: 0, systemLoad: 46.8)
        let glitch = PowerSnapshot(externalConnected: true, adapterPower: 0,
                                   batteryPower: -31.8, systemLoad: 31.8)
        let fixed = SampleGuard.reconcile(glitch, previous: good)
        XCTAssertEqual(fixed.adapterPower, 46.8, accuracy: 1e-9)
        XCTAssertEqual(fixed.systemLoad, 46.8, accuracy: 1e-9)
    }

    /// Actually unplugging must still come straight through.
    func testGenuineUnplugIsNotSuppressed() {
        let good = PowerSnapshot(externalConnected: true, adapterPower: 46.8,
                                 batteryPower: 0, systemLoad: 46.8)
        let unplugged = PowerSnapshot(externalConnected: false, adapterPower: 0,
                                      batteryPower: -14.3, systemLoad: 14.3)
        let fixed = SampleGuard.reconcile(unplugged, previous: good)
        XCTAssertFalse(fixed.externalConnected)
        XCTAssertEqual(fixed.adapterPower, 0)
        XCTAssertEqual(fixed.systemLoad, 14.3, accuracy: 1e-9)
    }

    /// A running machine always consumes something.
    func testZeroLoadIsRejected() {
        let good = PowerSnapshot(externalConnected: false, adapterPower: 0,
                                 batteryPower: -14.3, systemLoad: 14.3)
        let glitch = PowerSnapshot(externalConnected: false, adapterPower: 0,
                                   batteryPower: 0, systemLoad: 0)
        XCTAssertEqual(SampleGuard.reconcile(glitch, previous: good).systemLoad, 14.3, accuracy: 1e-9)
    }

    /// With no history there is nothing to fall back on.
    func testFirstSamplePassesThrough() {
        let first = PowerSnapshot(externalConnected: true, adapterPower: 0, systemLoad: 0)
        XCTAssertEqual(SampleGuard.reconcile(first, previous: nil).adapterPower, 0)
    }
}
