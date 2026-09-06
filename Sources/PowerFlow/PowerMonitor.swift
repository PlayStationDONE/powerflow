import AppKit
import Combine
import Foundation
import IOKit.ps
import PowerFlowKit
import SwiftUI

/// Polls the battery and publishes a smoothed snapshot.
///
/// Raw wattage readings jitter by a watt or so between samples. The diagram
/// shows two decimals, so an unfiltered feed makes the ribbons twitch
/// constantly; a light exponential filter keeps the numbers honest while the
/// geometry stays readable.
@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var snapshot: PowerSnapshot = .init()
    /// False on a machine with no battery, where the panel has nothing to draw.
    @Published private(set) var hasBattery = true
    /// Per-app draw, heaviest first, with the system remainder appended.
    @Published private(set) var rows: [DrawRow] = []
    /// Runtime left at the averaged load, e.g. "2h 18m".
    @Published private(set) var runtimeText: String?

    /// What the panel renders. Held still while the panel is closed.
    ///
    /// The diagram animates for slightly longer than the gap between readings,
    /// which is what makes the motion continuous - but it also means a new
    /// animation starts before the last one ends, so the view never settles.
    /// Left running behind a closed popover that is a permanent 120 fps render
    /// loop burning a third of a core, which is absurd in an app whose whole
    /// job is to watch power. Nothing is published to the panel unless someone
    /// is looking at it.
    @Published private(set) var panelSnapshot = PowerSnapshot()
    @Published private(set) var panelRows: [DrawRow] = []
    @Published private(set) var panelRuntime: String?

    /// Set by the popover when it opens and closes.
    var isPanelVisible = false {
        didSet {
            guard isPanelVisible, !oldValue else { return }
            // Opening after a while, the held values are stale. Catching up
            // with an animation would make the panel lurch from an old reading
            // to the current one every time it is opened, so the first publish
            // is instant and only later ones animate.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { publishToPanel() }
        }
    }

    private func publishToPanel() {
        panelSnapshot = snapshot
        panelRows = rows
        panelRuntime = runtimeText
    }

    private let reader = PowerReader()
    private var timer: Timer?
    private var smoothed: (adapter: Double, battery: Double, load: Double)?
    private let energy = AppEnergySampler()
    /// Runtime is quoted from an averaged load; an instantaneous reading swings
    /// the estimate between one hour and five.
    private var loadAverage = LoadAverager(window: 60)
    private var appTimer: Timer?
    /// Smoothed watts per pid. Raw per-sample values jitter enough to make rows
    /// trade places every few seconds, which is far more distracting than the
    /// small lag this introduces.
    private var appSmoothed: [Int32: Double] = [:]
    /// Enumerating every process is far heavier than reading three sensors, so
    /// it runs on its own slower cadence.
    private let appInterval: TimeInterval = Motion.appInterval
    /// Weight given to each new sample. Lower is calmer.
    private let alpha = 0.35

    init(startPolling: Bool = true) {
        refresh()
        guard startPolling else { return }
        let t = Timer(timeInterval: Motion.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        _ = energy.sample(appNames: RunningApps.names())
        let a = Timer(timeInterval: appInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshApps() }
        }
        RunLoop.main.add(a, forMode: .common)
        appTimer = a

        // Waking is the one moment everything is guaranteed stale: the SMC
        // connection may be dead, the readings are minutes old, and the load
        // average describes a machine that was asleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }


    private func handleWake() {
        reader.handleWake()
        smoothed = nil          // do not glide out of a stale reading
        loadAverage = LoadAverager(window: 60)
        appSmoothed.removeAll()
        _ = energy.sample(appNames: RunningApps.names())
        refresh()
    }

    deinit {
        timer?.invalidate()
        appTimer?.invalidate()
    }

    /// Rebuilds the per-app rows: the heaviest applications, then everything
    /// the kernel does not attribute to one - display, GPU, background daemons
    /// and the idle floor - so the column accounts for the whole system load.
    func refreshApps() {
        let measured = energy.sample(appNames: RunningApps.names())
        guard !measured.isEmpty else { return }

        var seen = Set<Int32>()
        var smoothedRows: [AppPower] = []
        for app in measured {
            seen.insert(app.pid)
            let previous = appSmoothed[app.pid] ?? app.watts
            let value = previous + (app.watts - previous) * 0.4
            appSmoothed[app.pid] = value
            smoothedRows.append(AppPower(pid: app.pid, name: app.name, watts: value))
        }
        appSmoothed = appSmoothed.filter { seen.contains($0.key) }
        smoothedRows.sort { ($0.watts, $1.name) > ($1.watts, $0.name) }

        // Below this a row says nothing useful and just looks broken.
        let top = Array(smoothedRows.filter { $0.watts >= 0.05 }.prefix(Ref.appRowCount))
        var out = top.map {
            DrawRow(id: $0.pid, name: $0.name, watts: $0.watts,
                    icon: RunningApps.icon(for: $0.pid), isSystem: false)
        }
        let attributed = smoothedRows.reduce(0) { $0 + $1.watts }
        let remainder = max(0, snapshot.systemLoad - attributed)
        out.append(DrawRow(id: -1, name: "System & display", watts: remainder,
                           icon: nil, isSystem: true))
        rows = out
        if isPanelVisible { panelRows = out }
    }

    func refresh() {
        guard var fresh = reader.read() else {
            hasBattery = false
            return
        }
        hasBattery = true
        fresh = SampleGuard.reconcile(fresh, previous: snapshot)

        if let prev = smoothed {
            fresh.adapterPower = blend(prev.adapter, fresh.adapterPower)
            fresh.batteryPower = blend(prev.battery, fresh.batteryPower)
            fresh.systemLoad = blend(prev.load, fresh.systemLoad)
        }
        smoothed = (fresh.adapterPower, fresh.batteryPower, fresh.systemLoad)
        snapshot = fresh

        loadAverage.add(fresh.systemLoad)
        runtimeText = RuntimeEstimate.format(RuntimeEstimate.seconds(
            remainingWh: fresh.remainingWh,
            load: loadAverage.average ?? fresh.systemLoad
        ))
        if isPanelVisible { publishToPanel() }
    }

    private func blend(_ old: Double, _ new: Double) -> Double {
        // Snap rather than glide when the state changes abruptly (plugging in,
        // waking from sleep), otherwise the diagram lags reality.
        if abs(new - old) > 25 { return new }
        return old + (new - old) * alpha
    }
}
