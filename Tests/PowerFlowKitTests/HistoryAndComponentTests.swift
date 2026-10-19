import Foundation
import Testing
@testable import PowerFlowKit

// All values in this file are simulated and used by unit tests only.

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("powerflow-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sample(_ t: TimeInterval, load: Double? = 20, adapter: Double? = 25, battery: Double? = 5) -> HistorySample {
    HistorySample(
        timestamp: Date(timeIntervalSince1970: t), percent: 80,
        externalConnected: true, isCharging: true,
        adapterWatts: adapter, batteryWatts: battery, systemLoadWatts: load,
        smcSystemTotalWatts: nil, gpuWatts: nil, source: .smc
    )
}

@Suite struct ComponentEnergyTrackerTests {
    @Test func frozenCounterIsNeverReportedAsZeroWatts() {
        var t = ComponentEnergyTracker()
        for _ in 0..<5 {
            let p = t.update(deltaJoules: [.cpu: 0, .gpu: 0], interval: 1)
            XCTAssertNil(p.cpu)
            XCTAssertNil(p.gpu)
        }
    }

    @Test func advancingCounterBecomesWatts() {
        var t = ComponentEnergyTracker()
        let p = t.update(deltaJoules: [.gpu: 0.5, .cpu: 0], interval: 2)
        XCTAssertEqual(p.gpu ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertNil(p.cpu)
    }

    @Test func onceAdvancedAZeroDeltaIsARealZero() {
        var t = ComponentEnergyTracker()
        _ = t.update(deltaJoules: [.gpu: 1], interval: 1)
        let p = t.update(deltaJoules: [.gpu: 0], interval: 1)
        XCTAssertEqual(p.gpu, 0)
    }

    @Test func nonsenseIsRejected() {
        var t = ComponentEnergyTracker()
        XCTAssertFalse(t.update(deltaJoules: [.gpu: -1], interval: 1).anyAvailable)
        XCTAssertFalse(t.update(deltaJoules: [.gpu: .nan], interval: 1).anyAvailable)
        XCTAssertFalse(t.update(deltaJoules: [.gpu: 1], interval: 0).anyAvailable)
        XCTAssertFalse(t.update(deltaJoules: [.gpu: 10_000], interval: 1).anyAvailable)
    }

    @Test func resetForgetsWhichCountersMoved() {
        var t = ComponentEnergyTracker()
        _ = t.update(deltaJoules: [.gpu: 1], interval: 1)
        t.reset()
        XCTAssertNil(t.update(deltaJoules: [.gpu: 0], interval: 1).gpu)
    }

    @Test func unitConversion() {
        XCTAssertEqual(EnergyUnit.joules(1500, unit: "mJ") ?? 0, 1.5, accuracy: 1e-12)
        XCTAssertEqual(EnergyUnit.joules(2_000_000, unit: "uJ") ?? 0, 2, accuracy: 1e-12)
        XCTAssertEqual(EnergyUnit.joules(3_000_000_000, unit: "nJ") ?? 0, 3, accuracy: 1e-12)
        XCTAssertNil(EnergyUnit.joules(1, unit: "kWh"))
    }
}

@Suite struct HistoryCSVTests {
    @Test func missingValuesAreEmptyCellsNotZero() {
        let row = HistoryCSV.row(HistorySample(timestamp: Date(timeIntervalSince1970: 0)))
        let cells = row.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(cells.count, HistoryCSV.columns.count)
        XCTAssertEqual(cells[0], "1970-01-01 00:00:00")
        XCTAssertTrue(cells[2...].allSatisfy { $0.isEmpty })
    }

    @Test func roundTripPreservesMissingAndZero() {
        let s = HistorySample(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), percent: 55.5,
            externalConnected: false, isCharging: false,
            adapterWatts: 0, batteryWatts: -12.345, systemLoadWatts: 12.345,
            smcSystemTotalWatts: nil, gpuWatts: nil, source: .registry
        )
        guard let back = HistoryCSV.parse(Substring(HistoryCSV.row(s))) else { return XCTFail("parse") }
        XCTAssertEqual(back.adapterWatts, 0)          // a real zero stays zero
        XCTAssertNil(back.smcSystemTotalWatts)        // missing stays missing
        XCTAssertNil(back.gpuWatts)
        XCTAssertEqual(back.batteryWatts ?? 0, -12.345, accuracy: 0.0005)
        XCTAssertEqual(back.externalConnected, false)
        XCTAssertEqual(back.source, .registry)
        XCTAssertEqual(back.timestamp, s.timestamp)
    }

    @Test func headerAndTornLinesAreRejected() {
        XCTAssertNil(HistoryCSV.parse(Substring(HistoryCSV.header)))
        XCTAssertNil(HistoryCSV.parse("1700000000,1,2"))
        XCTAssertNil(HistoryCSV.parse(""))
    }

    @Test func columnNamesCarryUnitsAndProvenance() {
        XCTAssertTrue(HistoryCSV.columns.contains("system_load_w_calculated"))
        XCTAssertTrue(HistoryCSV.columns.contains("adapter_input_w_direct"))
        XCTAssertTrue(HistoryCSV.columns.contains("gpu_w_ioreport"))
    }
}

@Suite struct HistoryStoreTests {
    @Test func batchesWritesUntilFlushThreshold() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(fileURL: dir.appendingPathComponent("h.csv"), flushEvery: 3)
        store.append(sample(1)); store.append(sample(2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.pendingCount, 2)
        store.append(sample(3))
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.load().count, 3)
    }

    @Test func fileAndDirectoryArePrivate() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("PowerFlow")
        let store = HistoryStore(fileURL: sub.appendingPathComponent("h.csv"), flushEvery: 1)
        store.append(sample(1))
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: sub.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
    }

    @Test func loadHonoursWindowAndSkipsTornLines() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(fileURL: dir.appendingPathComponent("h.csv"), flushEvery: 1)
        for t in [100.0, 200, 300] { store.append(sample(t)) }
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("garbage,line\n".utf8)); try handle.close()
        XCTAssertEqual(store.load().count, 3)
        XCTAssertEqual(store.load(since: Date(timeIntervalSince1970: 150)).count, 2)
    }

    @Test func pruneDropsOnlyExpiredRows() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(fileURL: dir.appendingPathComponent("h.csv"), retention: 1000, flushEvery: 1)
        for t in [0.0, 500, 1500, 2000] { store.append(sample(t)) }
        let removed = store.prune(now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(store.load().map { $0.timestamp.timeIntervalSince1970 }, [1500, 2000])
    }

    @Test func exportWritesHeaderAndRowsToChosenFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(fileURL: dir.appendingPathComponent("h.csv"), flushEvery: 1)
        store.append(sample(10)); store.append(sample(20))
        let out = dir.appendingPathComponent("export.csv")
        let exported = try store.export(to: out)
        XCTAssertEqual(exported, 2)
        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(HistoryCSV.header + "\n"))
        XCTAssertEqual(text.split(separator: "\n").count, 3)
    }

    @Test func exportRefusesToOverwriteTheStorageFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(fileURL: dir.appendingPathComponent("h.csv"), flushEvery: 1)
        store.append(sample(10))
        do { _ = try store.export(to: store.fileURL); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? HistoryError, .destinationIsStorageFile) }
        XCTAssertEqual(store.load().count, 1)
    }

    @Test func deleteRemovesOnlyTheHistoryFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let neighbour = dir.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: neighbour)
        let store = HistoryStore(fileURL: dir.appendingPathComponent("h.csv"), flushEvery: 5)
        store.append(sample(1))
        store.flush()
        store.append(sample(2))   // still buffered
        try store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
        XCTAssertEqual(store.load().count, 0)
    }

    @Test func unwritableLocationFailsWithoutCrashing() {
        let store = HistoryStore(fileURL: URL(fileURLWithPath: "/dev/null/nope/h.csv"), flushEvery: 1)
        store.append(sample(1))
        XCTAssertGreaterThan(store.pendingCount, 0)   // kept for retry, bounded
    }
}

@Suite struct HistorySeriesTests {
    @Test func gapsSplitSegmentsAndNothingIsInterpolated() {
        let samples = [sample(0), sample(5), sample(10), sample(100), sample(105)]
        let segs = HistorySeries.segments(samples, value: { $0.systemLoadWatts }, maxGap: 15)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].points.count, 3)
        XCTAssertEqual(segs[1].points.count, 2)
    }

    @Test func missingValueEndsASegmentInsteadOfBecomingZero() {
        let samples = [sample(0), sample(5, load: nil), sample(10)]
        let segs = HistorySeries.segments(samples, value: { $0.systemLoadWatts }, maxGap: 15)
        XCTAssertEqual(segs.count, 2)
        XCTAssertTrue(segs.flatMap(\.points).allSatisfy { $0.value == 20 })
    }

    @Test func decimationNeverSpansSegments() {
        let seg = SeriesSegment(points: (0..<10).map { (Date(timeIntervalSince1970: Double($0)), Double($0)) })
        let d = seg.decimated(bucket: 5)
        XCTAssertEqual(d.points.count, 2)
        XCTAssertEqual(d.points[0].value, 2, accuracy: 1e-9)
        XCTAssertEqual(d.points[1].value, 7, accuracy: 1e-9)
    }
}

@Suite struct PowerStatisticsTests {
    @Test func energyIsTrapezoidOverMeasuredTimeOnly() {
        // 10 W for 360 s = 1 Wh, then a 3640 s hole (skipped), then 10 W for
        // 180 s = 0.5 Wh.
        let samples = [sample(0, load: 10), sample(180, load: 10), sample(360, load: 10),
                       sample(4000, load: 10), sample(4180, load: 10)]
        let s = PowerStatistics.compute(samples, maxGap: 200)
        XCTAssertEqual(s.energyWh, 1.5, accuracy: 1e-9)
        XCTAssertEqual(s.measuredSeconds, 360 + 180, accuracy: 1e-9)
        XCTAssertEqual(s.averageWatts, 10)
        XCTAssertEqual(s.sampleCount, 5)
    }

    @Test func peakMinAndMissingValues() {
        let s = PowerStatistics.compute([sample(0, load: 5), sample(5, load: nil), sample(10, load: 30)])
        XCTAssertEqual(s.peakWatts, 30)
        XCTAssertEqual(s.minimumWatts, 5)
        XCTAssertEqual(s.sampleCount, 2)
        XCTAssertEqual(s.measuredSeconds, 0)     // the hole between them is not integrated
        XCTAssertEqual(s.energyWh, 0)
    }

    @Test func emptyInputHasNoAverage() {
        let s = PowerStatistics.compute([])
        XCTAssertNil(s.averageWatts)
        XCTAssertNil(s.peakWatts)
    }
}

@Suite struct CatalogAndSnapshotTests {
    @Test func unavailableComponentsAreListedAsUnavailable() {
        let items = MeasurementCatalog.descriptors(
            hasLiveSMC: true, hasSystemTotal: false, components: ComponentPower(gpu: 0.3)
        )
        func kind(_ id: String) -> MeasurementKind? { items.first { $0.id == id }?.kind }
        XCTAssertEqual(kind("gpu"), .direct)
        XCTAssertEqual(kind("cpu"), .unavailable)
        XCTAssertEqual(kind("pstr"), .unavailable)
        XCTAssertEqual(kind("wall"), .unavailable)
        XCTAssertEqual(kind("load"), .calculated)
        XCTAssertEqual(kind("apps"), .estimated)
    }

    @Test func snapshotCarriesSourceAndCrossCheck() {
        let live = SmartBatteryReader.snapshot(
            from: ["ExternalConnected": true, "CurrentCapacity": 50, "MaxCapacity": 100],
            smc: SMCPower(adapter: 30, battery: 5, systemTotal: 24.5)
        )
        XCTAssertEqual(live.dataSource, .smc)
        XCTAssertEqual(live.smcSystemTotal, 24.5)
        XCTAssertEqual(live.systemLoad, 25, accuracy: 1e-9)
        let slow = SmartBatteryReader.snapshot(from: ["CurrentCapacity": 50, "MaxCapacity": 100])
        XCTAssertEqual(slow.dataSource, .registry)
        XCTAssertNil(slow.smcSystemTotal)
    }

    @Test func dischargingOnBatteryReportsNegativeBatteryPower() {
        let s = SmartBatteryReader.snapshot(
            from: ["ExternalConnected": false, "CurrentCapacity": 60, "MaxCapacity": 100],
            smc: SMCPower(adapter: 0, battery: -14)
        )
        XCTAssertEqual(s.batteryPower, -14, accuracy: 1e-9)
        XCTAssertEqual(s.systemLoad, 14, accuracy: 1e-9)
        XCTAssertEqual(s.adapterPower, 0)
    }
}
