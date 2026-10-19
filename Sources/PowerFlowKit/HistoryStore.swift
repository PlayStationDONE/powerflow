import Foundation

/// One recorded instant. Every power field is optional: **nil means "not
/// measured"**, which is stored as an empty CSV cell and is never confused with
/// 0 W.
public struct HistorySample: Equatable, Sendable {
    public var timestamp: Date
    public var percent: Double?
    public var externalConnected: Bool?
    public var isCharging: Bool?
    /// Direct: SMC `PDTR`.
    public var adapterWatts: Double?
    /// Calculated: pack voltage x pack current. Positive is into the battery.
    public var batteryWatts: Double?
    /// Calculated: adapter - battery.
    public var systemLoadWatts: Double?
    /// Direct: SMC `PSTR`, an independent cross-check.
    public var smcSystemTotalWatts: Double?
    /// Direct: IOReport GPU energy.
    public var gpuWatts: Double?
    public var source: PowerDataSource?

    public init(
        timestamp: Date,
        percent: Double? = nil,
        externalConnected: Bool? = nil,
        isCharging: Bool? = nil,
        adapterWatts: Double? = nil,
        batteryWatts: Double? = nil,
        systemLoadWatts: Double? = nil,
        smcSystemTotalWatts: Double? = nil,
        gpuWatts: Double? = nil,
        source: PowerDataSource? = nil
    ) {
        self.timestamp = timestamp
        self.percent = percent
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.adapterWatts = adapterWatts
        self.batteryWatts = batteryWatts
        self.systemLoadWatts = systemLoadWatts
        self.smcSystemTotalWatts = smcSystemTotalWatts
        self.gpuWatts = gpuWatts
        self.source = source
    }
}

/// CSV encoding shared by the on-disk log and the export, so what is exported
/// is exactly what is stored. Plain RFC 4180 with a header row, no quoting
/// needed (all fields are numbers or fixed tokens), UTF-8, LF line ends.
/// Excel and Power BI both read it directly.
public enum HistoryCSV {
    public static let columns = [
        "timestamp_utc",
        "unix_seconds",
        "battery_percent",
        "external_connected",
        "charging",
        "adapter_input_w_direct",
        "battery_w_calculated",
        "system_load_w_calculated",
        "system_total_w_smc_pstr",
        "gpu_w_ioreport",
        "power_source",
    ]
    public static var header: String { columns.joined(separator: ",") }

    /// "yyyy-MM-dd HH:mm:ss" in UTC, which Excel and Power BI parse as a
    /// datetime. Uses gmtime_r: thread-safe and far cheaper than a formatter
    /// when rewriting a week of rows.
    static func utcString(_ date: Date) -> String {
        var t = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        gmtime_r(&t, &parts)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                      Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
                      Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec))
    }

    private static func number(_ v: Double?, digits: Int) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(digits)f", v)
    }

    private static func flag(_ v: Bool?) -> String {
        guard let v else { return "" }
        return v ? "1" : "0"
    }

    public static func row(_ s: HistorySample) -> String {
        [
            utcString(s.timestamp),
            String(format: "%.0f", s.timestamp.timeIntervalSince1970.rounded(.down)),
            number(s.percent, digits: 1),
            flag(s.externalConnected),
            flag(s.isCharging),
            number(s.adapterWatts, digits: 3),
            number(s.batteryWatts, digits: 3),
            number(s.systemLoadWatts, digits: 3),
            number(s.smcSystemTotalWatts, digits: 3),
            number(s.gpuWatts, digits: 3),
            s.source?.rawValue ?? "",
        ].joined(separator: ",")
    }

    /// Parses one data row; returns nil for a header, a blank line or a torn
    /// write (wrong column count, unparseable timestamp).
    public static func parse(_ line: Substring) -> HistorySample? {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count == columns.count, let unix = Double(f[1]) else { return nil }
        func d(_ i: Int) -> Double? { f[i].isEmpty ? nil : Double(f[i]) }
        func b(_ i: Int) -> Bool? {
            switch f[i] { case "1": return true; case "0": return false; default: return nil }
        }
        return HistorySample(
            timestamp: Date(timeIntervalSince1970: unix),
            percent: d(2), externalConnected: b(3), isCharging: b(4),
            adapterWatts: d(5), batteryWatts: d(6), systemLoadWatts: d(7),
            smcSystemTotalWatts: d(8), gpuWatts: d(9),
            source: PowerDataSource(rawValue: String(f[10]))
        )
    }
}

public enum HistoryError: Error, Equatable {
    case destinationIsStorageFile
}

/// Append-only local log in the app's own Application Support folder.
///
/// * The directory is created `0700` and the file `0600`.
/// * Writes are batched (`flushEvery` samples) so the disk is touched about
///   once a minute rather than every sample.
/// * Retention is bounded: `prune` rewrites the file without rows older than
///   `retention`, atomically.
/// * Nothing leaves the machine; this class has no network code.
public final class HistoryStore {
    public let fileURL: URL
    public let retention: TimeInterval
    public let flushEvery: Int

    private var pending: [String] = []
    private let fm = FileManager.default

    /// `~/Library/Application Support/PowerFlow/history.csv`
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PowerFlow", isDirectory: true)
            .appendingPathComponent("history.csv")
    }

    public init(fileURL: URL = HistoryStore.defaultFileURL(),
                retention: TimeInterval = 7 * 24 * 3600,
                flushEvery: Int = 12) {
        self.fileURL = fileURL
        self.retention = retention
        self.flushEvery = max(1, flushEvery)
    }

    public var pendingCount: Int { pending.count }

    public func append(_ sample: HistorySample) {
        pending.append(HistoryCSV.row(sample))
        if pending.count >= flushEvery { flush() }
    }

    /// Writes buffered rows. Failure keeps them buffered for the next attempt,
    /// bounded so a read-only disk cannot grow memory without limit.
    @discardableResult
    public func flush() -> Bool {
        guard !pending.isEmpty else { return true }
        do {
            try ensureFile()
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((pending.joined(separator: "\n") + "\n").utf8))
            pending.removeAll(keepingCapacity: true)
            return true
        } catch {
            if pending.count > 10_000 { pending.removeFirst(pending.count - 10_000) }
            return false
        }
    }

    private func ensureFile() throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: fileURL.path) {
            let created = fm.createFile(
                atPath: fileURL.path,
                contents: Data((HistoryCSV.header + "\n").utf8),
                attributes: [.posixPermissions: 0o600]
            )
            if !created { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Loads stored samples (flushing first), oldest first, optionally limited
    /// to a time window. Malformed lines are skipped.
    public func load(since: Date? = nil) -> [HistorySample] {
        flush()
        return Self.readFile(fileURL, since: since)
    }

    /// Read-only and free of instance state, so it can run off the main thread
    /// after `flush()`.
    public static func readFile(_ fileURL: URL, since: Date? = nil) -> [HistorySample] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [HistorySample] = []
        for line in text.split(separator: "\n") {
            guard let s = HistoryCSV.parse(line) else { continue }
            if let since, s.timestamp < since { continue }
            out.append(s)
        }
        return out
    }

    /// Drops rows older than the retention window. Returns rows removed.
    @discardableResult
    public func prune(now: Date = Date()) -> Int {
        flush()
        guard fm.fileExists(atPath: fileURL.path) else { return 0 }
        let all = load()
        let keep = all.filter { now.timeIntervalSince($0.timestamp) <= retention }
        guard keep.count != all.count else { return 0 }
        let body = ([HistoryCSV.header] + keep.map(HistoryCSV.row)).joined(separator: "\n") + "\n"
        do {
            try Data(body.utf8).write(to: fileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { return 0 }
        return all.count - keep.count
    }

    /// Copies the log to `destination` (a user-chosen file) for the given
    /// window. The storage file itself is never a valid destination.
    @discardableResult
    public func export(to destination: URL, since: Date? = nil) throws -> Int {
        if destination.standardizedFileURL.resolvingSymlinksInPath()
            == fileURL.standardizedFileURL.resolvingSymlinksInPath() {
            throw HistoryError.destinationIsStorageFile
        }
        let rows = load(since: since)
        let body = ([HistoryCSV.header] + rows.map(HistoryCSV.row)).joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: destination, options: .atomic)
        return rows.count
    }

    /// Deletes all stored history and anything buffered. Only this store's own
    /// file is touched.
    public func deleteAll() throws {
        pending.removeAll()
        if fm.fileExists(atPath: fileURL.path) { try fm.removeItem(at: fileURL) }
    }
}

// MARK: - presentation helpers

/// A run of consecutive points with no sampling gap, so charts never draw a
/// line across time the app was not measuring (sleep, app not running, a
/// source that dropped out).
public struct SeriesSegment: Equatable, Sendable {
    public var points: [(date: Date, value: Double)]
    public static func == (a: SeriesSegment, b: SeriesSegment) -> Bool {
        a.points.count == b.points.count && zip(a.points, b.points).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

public enum HistorySeries {
    /// Splits `samples` into gap-free segments of one field. A missing value or
    /// a time gap longer than `maxGap` ends the current segment; nothing is
    /// interpolated across it.
    public static func segments(
        _ samples: [HistorySample],
        value: (HistorySample) -> Double?,
        maxGap: TimeInterval
    ) -> [SeriesSegment] {
        var out: [SeriesSegment] = []
        var current: [(date: Date, value: Double)] = []
        var last: Date?
        func close() {
            if !current.isEmpty { out.append(SeriesSegment(points: current)) }
            current = []
        }
        for s in samples {
            if let last, s.timestamp.timeIntervalSince(last) > maxGap { close() }
            last = s.timestamp
            if let v = value(s), v.isFinite { current.append((s.timestamp, v)) } else { close() }
        }
        close()
        return out
    }
}

extension SeriesSegment {
    /// Averages points in `bucket`-second windows within this segment, so a
    /// long range stays cheap to draw. Windows never span a segment boundary,
    /// so no value is produced for time that was not measured.
    public func decimated(bucket: TimeInterval) -> SeriesSegment {
        guard bucket > 0, points.count > 1 else { return self }
        var out: [(date: Date, value: Double)] = []
        var i = 0
        while i < points.count {
            let start = floor(points[i].date.timeIntervalSince1970 / bucket) * bucket
            var sum = 0.0, n = 0
            while i < points.count, points[i].date.timeIntervalSince1970 < start + bucket {
                sum += points[i].value; n += 1; i += 1
            }
            out.append((Date(timeIntervalSince1970: start + bucket / 2), sum / Double(n)))
        }
        return SeriesSegment(points: out)
    }
}

/// Running statistics for this app session (or any list of samples), computed
/// only from measured values. Energy is the trapezoid integral of system load
/// over intervals no longer than `maxGap`; gaps are skipped, not filled.
public struct PowerStatistics: Equatable, Sendable {
    public var sampleCount = 0
    public var averageWatts: Double?
    public var peakWatts: Double?
    public var minimumWatts: Double?
    /// Watt-hours consumed over the *measured* time.
    public var energyWh: Double = 0
    /// Seconds actually covered by measurements.
    public var measuredSeconds: Double = 0

    public init() {}

    public static func compute(
        _ samples: [HistorySample],
        value: (HistorySample) -> Double? = { $0.systemLoadWatts },
        maxGap: TimeInterval = 15
    ) -> PowerStatistics {
        var stats = PowerStatistics()
        var sum = 0.0
        var prev: (Date, Double)?
        for s in samples {
            guard let v = value(s), v.isFinite else { prev = nil; continue }
            stats.sampleCount += 1
            sum += v
            stats.peakWatts = max(stats.peakWatts ?? v, v)
            stats.minimumWatts = min(stats.minimumWatts ?? v, v)
            if let (t0, v0) = prev {
                let dt = s.timestamp.timeIntervalSince(t0)
                if dt > 0, dt <= maxGap {
                    stats.energyWh += (v0 + v) / 2 * dt / 3600
                    stats.measuredSeconds += dt
                }
            }
            prev = (s.timestamp, v)
        }
        if stats.sampleCount > 0 { stats.averageWatts = sum / Double(stats.sampleCount) }
        return stats
    }
}
