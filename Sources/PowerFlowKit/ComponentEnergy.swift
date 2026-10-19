import Darwin
import Foundation

/// Power of individual SoC blocks, in watts. A nil field means "not measured",
/// never zero.
public struct ComponentPower: Equatable, Sendable {
    public var cpu: Double?
    public var gpu: Double?
    public var ane: Double?
    public var dram: Double?

    public init(cpu: Double? = nil, gpu: Double? = nil, ane: Double? = nil, dram: Double? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.ane = ane
        self.dram = dram
    }

    public static let none = ComponentPower()
    public var anyAvailable: Bool { cpu != nil || gpu != nil || ane != nil || dram != nil }
}

public enum EnergyComponent: String, CaseIterable, Sendable {
    case cpu, gpu, ane, dram
}

/// Unit conversion for IOReport energy channels.
public enum EnergyUnit {
    public static func joules(_ value: Int64, unit: String) -> Double? {
        switch unit {
        case "mJ": return Double(value) * 1e-3
        case "uJ": return Double(value) * 1e-6
        case "nJ": return Double(value) * 1e-9
        default: return nil
        }
    }
}

/// Turns per-interval energy deltas into watts and refuses to report a block
/// whose counter has never moved.
///
/// On the M1 Pro under macOS 27 the `CPU Energy`, `DRAM0` and `ANE0` channels
/// return the same cumulative value on every read, while `GPU Energy` advances.
/// Reporting "0 W" for a CPU that is plainly working would be a fabricated
/// measurement, so a block is only reported once its counter has been seen to
/// advance at least once.
public struct ComponentEnergyTracker: Sendable {
    private var advanced: Set<EnergyComponent> = []
    /// Anything above this is a counter glitch, not a reading.
    public static let plausibleMaxWatts = 150.0

    public init() {}

    public mutating func update(deltaJoules: [EnergyComponent: Double], interval: Double) -> ComponentPower {
        guard interval > 0, interval.isFinite else { return .none }
        var out = ComponentPower()
        for (component, joules) in deltaJoules {
            guard joules.isFinite, joules >= 0 else { continue }
            if joules > 0 { advanced.insert(component) }
            guard advanced.contains(component) else { continue }
            let watts = joules / interval
            guard watts <= Self.plausibleMaxWatts else { continue }
            switch component {
            case .cpu: out.cpu = watts
            case .gpu: out.gpu = watts
            case .ane: out.ane = watts
            case .dram: out.dram = watts
            }
        }
        return out
    }

    public mutating func reset() { advanced.removeAll() }
}

/// Reads the "Energy Model" group of IOReport. No root and no entitlement are
/// needed, but IOReport is **not a documented API**: it is loaded at run time
/// from its fixed system path, and the app keeps working (with those figures
/// marked unavailable) if it is missing or changes.
public final class ComponentEnergyReader {
    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StringGetter = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerGetter = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let channelName: StringGetter
    private let unitLabel: StringGetter
    private let integerValue: IntegerGetter
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary

    private var previous: CFDictionary?
    private var previousAt: TimeInterval?
    private var tracker = ComponentEnergyTracker()

    /// Logical block -> IOReport channel names, in order of preference.
    private static let channelNames: [EnergyComponent: [String]] = [
        .cpu: ["CPU Energy"],
        .gpu: ["GPU Energy"],
        .ane: ["ANE0"],
        .dram: ["DRAM0"],
    ]

    public init?() {
        // Fixed absolute path: the library lives in the dyld shared cache.
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let copy = symbol("IOReportCopyChannelsInGroup", as: CopyChannels.self),
              let subscribe = symbol("IOReportCreateSubscription", as: CreateSubscription.self),
              let samples = symbol("IOReportCreateSamples", as: CreateSamples.self),
              let delta = symbol("IOReportCreateSamplesDelta", as: CreateDelta.self),
              let name = symbol("IOReportChannelGetChannelName", as: StringGetter.self),
              let unit = symbol("IOReportChannelGetUnitLabel", as: StringGetter.self),
              let integer = symbol("IOReportSimpleGetIntegerValue", as: IntegerGetter.self),
              let wanted = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = subscribe(nil, wanted, &subscribed, 0, nil),
              let subscribedChannels = subscribed?.takeUnretainedValue()
        else { return nil }

        createSamples = samples
        createDelta = delta
        channelName = name
        unitLabel = unit
        integerValue = integer
        subscription = sub
        // The call hands back an owned (+1) dictionary; the subscription needs
        // it for as long as this reader lives, so the extra count is left.
        channels = subscribedChannels
    }

    /// Forget the previous sample, e.g. after wake: a delta across sleep would
    /// average a few watts over hours of nothing.
    public func reset() {
        previous = nil
        previousAt = nil
        tracker.reset()
    }

    /// Takes a sample and returns watts since the previous one. The first call
    /// only establishes a baseline and returns `.none`.
    public func sample() -> ComponentPower {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return .none }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = current; previousAt = now }
        guard let previous, let previousAt,
              let diff = createDelta(previous, current, nil)?.takeRetainedValue() as? [String: Any],
              let items = diff["IOReportChannels"] as? [CFDictionary]
        else { return .none }

        var byName: [String: Double] = [:]
        for item in items {
            guard let name = channelName(item)?.takeUnretainedValue() as String?,
                  let unit = unitLabel(item)?.takeUnretainedValue() as String?,
                  let joules = EnergyUnit.joules(integerValue(item, 0), unit: unit)
            else { continue }
            if byName[name] == nil { byName[name] = joules }
        }

        var deltas: [EnergyComponent: Double] = [:]
        for (component, names) in Self.channelNames {
            if let value = names.compactMap({ byName[$0] }).first { deltas[component] = value }
        }
        return tracker.update(deltaJoules: deltas, interval: now - previousAt)
    }
}
