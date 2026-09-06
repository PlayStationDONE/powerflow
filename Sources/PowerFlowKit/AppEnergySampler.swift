import Darwin
import Foundation

/// One process's cumulative energy counter at a moment in time.
public struct ProcessSample: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let name: String
    /// `ri_energy_nj`, the kernel's cumulative energy attribution in nanojoules.
    public let energyNanojoules: UInt64

    public init(pid: Int32, ppid: Int32, name: String, energyNanojoules: UInt64) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.energyNanojoules = energyNanojoules
    }
}

/// An app's share of power, in watts.
public struct AppPower: Equatable, Sendable, Identifiable {
    public let pid: Int32
    public let name: String
    public let watts: Double
    public var id: Int32 { pid }

    public init(pid: Int32, name: String, watts: Double) {
        self.pid = pid
        self.name = name
        self.watts = watts
    }
}

/// Turns two sets of process energy counters into per-app wattage.
///
/// Helper processes are folded into the app that spawned them by walking the
/// parent chain, so a browser's twenty renderers appear as one row rather than
/// burying everything else.
public enum AppPowerAggregator {

    /// - Parameters:
    ///   - previous: counters from the earlier sample, keyed by pid.
    ///   - current: counters from the later sample.
    ///   - interval: seconds between the two samples.
    ///   - appNames: display names for pids that are user-facing applications.
    ///     A process whose ancestor appears here is attributed to that ancestor.
    public static func aggregate(
        previous: [Int32: ProcessSample],
        current: [ProcessSample],
        interval: Double,
        appNames: [Int32: String] = [:]
    ) -> [AppPower] {
        guard interval > 0 else { return [] }

        let byPid = Dictionary(uniqueKeysWithValues: current.map { ($0.pid, $0) })
        var totals: [Int32: (name: String, joules: Double)] = [:]

        for sample in current {
            guard let before = previous[sample.pid] else { continue }
            // A counter that went backwards means the pid was recycled.
            guard sample.energyNanojoules >= before.energyNanojoules else { continue }
            let joules = Double(sample.energyNanojoules - before.energyNanojoules) / 1e9
            guard joules > 0 else { continue }

            let owner = root(of: sample, in: byPid, appNames: appNames)
            let name = appNames[owner.pid] ?? owner.name
            totals[owner.pid, default: (name, 0)].joules += joules
        }

        return totals
            .map { AppPower(pid: $0.key, name: $0.value.name, watts: $0.value.joules / interval) }
            .sorted { ($0.watts, $1.name) > ($1.watts, $0.name) }
    }

    /// Walks up the parent chain to the owning application, stopping at the
    /// first ancestor that is a known app. Falls back to the topmost ancestor
    /// still owned by the session.
    private static func root(
        of sample: ProcessSample,
        in byPid: [Int32: ProcessSample],
        appNames: [Int32: String]
    ) -> ProcessSample {
        if appNames[sample.pid] != nil { return sample }
        var node = sample
        var hops = 0
        while hops < 12, node.ppid > 1, let parent = byPid[node.ppid] {
            if appNames[parent.pid] != nil { return parent }
            node = parent
            hops += 1
        }
        return sample
    }
}

/// Reads every readable process's energy counter.
///
/// `proc_pid_rusage` succeeds for processes the current user owns, which covers
/// the apps a person actually runs; root-owned daemons are skipped rather than
/// guessed at.
public final class AppEnergySampler {
    private var previous: [Int32: ProcessSample] = [:]
    private var lastSampledAt: Date?

    public init() {}

    /// Samples now and returns per-app watts measured since the previous call.
    /// The first call has nothing to compare against and returns an empty list.
    public func sample(appNames: [Int32: String] = [:], now: Date = Date()) -> [AppPower] {
        let current = Self.readAll()
        defer {
            previous = Dictionary(uniqueKeysWithValues: current.map { ($0.pid, $0) })
            lastSampledAt = now
        }
        guard let last = lastSampledAt else { return [] }
        return AppPowerAggregator.aggregate(
            previous: previous,
            current: current,
            interval: now.timeIntervalSince(last),
            appNames: appNames
        )
    }

    /// Total energy counter across all readable processes, for diagnostics.
    public static func readAll() -> [ProcessSample] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) / MemoryLayout<Int32>.size)
        let used = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, count)
        guard used > 0 else { return [] }

        var out: [ProcessSample] = []
        out.reserveCapacity(pids.count)
        for pid in pids.prefix(Int(used) / MemoryLayout<Int32>.size) where pid > 0 {
            guard let energy = energyNanojoules(pid) else { continue }
            out.append(ProcessSample(
                pid: pid,
                ppid: parentPid(pid),
                name: processName(pid),
                energyNanojoules: energy
            ))
        }
        return out
    }

    private static func energyNanojoules(_ pid: Int32) -> UInt64? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? usage.ri_energy_nj : nil
    }

    private static func parentPid(_ pid: Int32) -> Int32 {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        return got == size ? Int32(bitPattern: info.pbsi_ppid) : 0
    }

    private static func processName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : "pid \(pid)"
    }
}
