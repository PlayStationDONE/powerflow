import Foundation

/// How a displayed quantity was obtained. The UI, the CSV export and the
/// documentation all use these four words with the same meaning.
public enum MeasurementKind: String, Codable, Sendable, CaseIterable {
    /// Reported by a system interface as-is (a sensor or counter).
    case direct
    /// Arithmetic on direct readings (a sum, a difference, V x A, an integral).
    case calculated
    /// A model or attribution, not a physical measurement.
    case estimated
    /// This Mac / macOS version does not expose it, or the source is not
    /// producing credible values. Never shown as a number.
    case unavailable

    public var label: String {
        switch self {
        case .direct: return "Direct"
        case .calculated: return "Calculated"
        case .estimated: return "Estimated"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Where the live wattages in a snapshot came from.
public enum PowerDataSource: String, Codable, Sendable {
    /// SMC sensors, refreshed about once a second.
    case smc
    /// `AppleSmartBattery` registry entry, which republishes about once a minute.
    case registry
}

/// One row of the measurement catalogue: the single place that says what each
/// metric is, where it comes from and what it cannot tell you.
public struct MetricDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: MeasurementKind
    public let source: String
    public let note: String

    public init(id: String, name: String, kind: MeasurementKind, source: String, note: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.source = source
        self.note = note
    }
}

public enum MeasurementCatalog {
    /// Builds the catalogue for the current machine. `kind` reflects what this
    /// Mac is actually producing right now, so a source that has gone quiet is
    /// listed as unavailable rather than silently omitted.
    public static func descriptors(
        hasLiveSMC: Bool,
        hasSystemTotal: Bool,
        components: ComponentPower
    ) -> [MetricDescriptor] {
        func component(_ id: String, _ name: String, _ value: Double?, _ source: String) -> MetricDescriptor {
            MetricDescriptor(
                id: id, name: name,
                kind: value == nil ? .unavailable : .direct,
                source: source,
                note: value == nil
                    ? "The IOReport counter for this block is not advancing on this Mac, so no value is shown."
                    : "Energy counter delta divided by the elapsed time. Covers this block only, not the whole SoC."
            )
        }
        return [
            MetricDescriptor(
                id: "adapter", name: "Adapter input",
                kind: hasLiveSMC ? .direct : .calculated,
                source: hasLiveSMC ? "SMC key PDTR" : "AppleSmartBattery PowerTelemetryData (about 1/min)",
                note: "Power the adapter delivers to the Mac as seen by the power-management hardware. This is not AC wall power: conversion losses before the Mac are not included."
            ),
            MetricDescriptor(
                id: "battery", name: "Battery power",
                kind: .calculated,
                source: hasLiveSMC ? "SMC B0AV (V) x B0AC (A)" : "AppleSmartBattery Voltage x Amperage",
                note: "Positive is into the battery. Pack voltage times pack current."
            ),
            MetricDescriptor(
                id: "load", name: "System load",
                kind: .calculated,
                source: "adapter input - battery power",
                note: "Derived so the three flows always balance. Whole-machine consumption including display, SSD and radios."
            ),
            MetricDescriptor(
                id: "pstr", name: "System total (cross-check)",
                kind: hasSystemTotal ? .direct : .unavailable,
                source: "SMC key PSTR",
                note: "A second, independently sampled whole-system figure. Apple does not document the key; it is shown only to cross-check the derived load and the two can differ by several watts."
            ),
            component("gpu", "GPU power", components.gpu, "IOReport Energy Model: GPU Energy"),
            component("cpu", "CPU power", components.cpu, "IOReport Energy Model: CPU Energy"),
            component("ane", "Neural Engine power", components.ane, "IOReport Energy Model: ANE"),
            component("dram", "Memory power", components.dram, "IOReport Energy Model: DRAM"),
            MetricDescriptor(
                id: "soc", name: "Total SoC power",
                kind: .unavailable,
                source: "-",
                note: "Not shown: the unprivileged counters do not cover every SoC block, and summing the ones that work would understate it."
            ),
            MetricDescriptor(
                id: "wall", name: "Wall (AC outlet) power",
                kind: .unavailable,
                source: "-",
                note: "macOS does not expose AC-side power. Battery telemetry cannot measure it; a plug-in power meter can."
            ),
            MetricDescriptor(
                id: "apps", name: "Per-app power",
                kind: .estimated,
                source: "proc_pid_rusage ri_energy_nj",
                note: "The kernel's CPU energy attribution, divided by elapsed time. It captures roughly half of real power and omits root-owned processes, the GPU and the display."
            ),
            MetricDescriptor(
                id: "runtime", name: "Runtime if unplugged",
                kind: .estimated,
                source: "remaining Wh / 60 s average load",
                note: "Assumes the load stays as it has been for the last minute. Pack energy uses a nominal 3.8 V per cell."
            ),
            MetricDescriptor(
                id: "health", name: "Battery health, cycles, temperature",
                kind: .direct,
                source: "AppleSmartBattery",
                note: "Slow-moving pack diagnostics. Health is capacity, not power."
            ),
        ]
    }
}
