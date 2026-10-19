import AppKit
import Charts
import PowerFlowKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Liquid Glass surface

/// The one place glass is applied. Liquid Glass (macOS 26+) is used for the
/// small set of content cards that float over the window; older systems get a
/// system material, and Reduce Transparency gets an opaque system colour.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 16
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(shape.fill(Color(nsColor: .controlBackgroundColor)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}

/// "Direct / Calculated / Estimated / Unavailable" chip. Text, not just colour,
/// carries the meaning.
struct KindBadge: View {
    let kind: MeasurementKind

    var body: some View {
        Text(kind.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
            .accessibilityLabel("\(kind.label) measurement")
    }

    private var tint: Color {
        switch kind {
        case .direct: return .green
        case .calculated: return .blue
        case .estimated: return .orange
        case .unavailable: return .secondary
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var monitor: PowerMonitor
    @ObservedObject var settings = Settings.shared
    @State private var tab: Tab = .live
    @State private var message: String?

    enum Tab: String, CaseIterable, Identifiable {
        case live = "Live", history = "History", apps = "Apps", sources = "Sources"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
                FreshnessLabel(monitor: monitor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Group {
                if !monitor.hasBattery {
                    ContentUnavailableView(
                        "No battery",
                        systemImage: "desktopcomputer",
                        description: Text("PowerFlow measures laptop battery power flow.")
                    )
                } else {
                    switch tab {
                    case .live: LiveTab(monitor: monitor)
                    case .history: HistoryTab(monitor: monitor, settings: settings)
                    case .apps: AppsTab(monitor: monitor)
                    case .sources: SourcesTab(monitor: monitor)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(.background)
    }
}

struct FreshnessLabel: View {
    @ObservedObject var monitor: PowerMonitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let text: String = {
                guard let t = monitor.lastReading else { return "No reading yet" }
                let age = max(0, Int(context.date.timeIntervalSince(t)))
                return age < 2 ? "Updated just now" : "Updated \(age) s ago"
            }()
            let source = monitor.snapshot.dataSource == .smc ? "SMC sensors, ~1 s" : "Battery registry, ~1 min"
            Text("\(text)  \u{00B7}  \(source)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Live

private struct Tile: View {
    let title: String
    let value: String
    let kind: MeasurementKind
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                KindBadge(kind: kind)
            }
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(kind == .unavailable ? .secondary : .primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .glassSurface()
        .accessibilityElement(children: .combine)
    }
}

private func watts(_ v: Double?) -> String {
    guard let v else { return "\u{2014}" }
    return String(format: "%.1f W", v)
}

struct LiveTab: View {
    @ObservedObject var monitor: PowerMonitor

    private var s: PowerSnapshot { monitor.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    Tile(title: "Adapter input", value: s.externalConnected ? watts(s.adapterPower) : "Unplugged",
                         kind: s.externalConnected ? (s.dataSource == .smc ? .direct : .calculated) : .calculated,
                         detail: s.adapterName ?? "Power delivered to the Mac by the adapter. Not wall power.")
                    Tile(title: batteryTitle, value: watts(abs(s.batteryPower)),
                         kind: .calculated, detail: "Pack voltage \u{00D7} current. Positive means charging.")
                    Tile(title: "System total (PSTR)", value: watts(s.smcSystemTotal),
                         kind: s.smcSystemTotal == nil ? .unavailable : .direct,
                         detail: crossCheckDetail)
                    Tile(title: "GPU", value: watts(monitor.components.gpu),
                         kind: monitor.components.gpu == nil ? .unavailable : .direct,
                         detail: monitor.components.gpu == nil
                            ? "Counter not available on this Mac." : "GPU block only.")
                    Tile(title: "CPU", value: watts(monitor.components.cpu),
                         kind: monitor.components.cpu == nil ? .unavailable : .direct,
                         detail: monitor.components.cpu == nil
                            ? "macOS does not expose a live CPU power counter here without root."
                            : "CPU block only.")
                    Tile(title: "Wall (AC) power", value: "\u{2014}", kind: .unavailable,
                         detail: "macOS cannot report outlet power. Use a plug-in meter for that.")
                }
                HStack(alignment: .top, spacing: 12) {
                    batteryCard
                    sessionCard
                }
                flowCard
            }
            .padding(20)
        }
    }

    private var batteryTitle: String {
        if s.batteryPower > 0.05 { return "Battery (charging)" }
        if s.batteryPower < -0.05 { return "Battery (discharging)" }
        return "Battery (idle)"
    }

    private var crossCheckDetail: String {
        guard let t = s.smcSystemTotal else { return "This key is not reported on this Mac." }
        let diff = t - s.systemLoad
        return String(format: "Cross-check only; %+.1f W vs the derived load. Sensors are sampled at different times.", diff)
    }

    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("System load").font(.headline).foregroundStyle(.secondary)
                Text(String(format: "%.1f W", s.systemLoad))
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    // No rolling-digit transition here: it renders through a CPU
                    // blur and, at one update a second, cost ~25% of a core.
                Text("Adapter input \u{2212} battery power. Whole-machine consumption, lightly smoothed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            KindBadge(kind: .calculated)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: "System load %.1f watts, calculated", s.systemLoad))
    }

    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Battery", systemImage: "battery.75").font(.headline)
            row("Charge", String(format: "%.0f%%", s.percent))
            row("State", stateText)
            row("Runtime if unplugged", monitor.runtimeText ?? "\u{2014}", kind: .estimated)
            Divider()
            row("Health (capacity)", s.health.map { String(format: "%.0f%%", $0) } ?? "\u{2014}")
            row("Cycles", s.cycleCount.map(String.init) ?? "\u{2014}")
            row("Temperature", s.temperature.map { String(format: "%.1f \u{00B0}C", $0) } ?? "\u{2014}")
            Text("Health is how much charge the pack holds, not how much power is being used.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassSurface()
    }

    private var stateText: String {
        if s.fullyCharged { return "Full" }
        if s.isCharging { return "Charging" }
        if s.externalConnected { return s.chargingPaused ? "On AC, charging paused" : "On AC" }
        return "On battery"
    }

    private var sessionCard: some View {
        let stats = monitor.sessionStats
        return VStack(alignment: .leading, spacing: 8) {
            Label("This session", systemImage: "chart.bar").font(.headline)
            row("Average load", watts(stats.averageWatts), kind: .calculated)
            row("Peak load", watts(stats.peakWatts), kind: .calculated)
            row("Energy used", stats.sampleCount > 1 ? String(format: "%.2f Wh", stats.energyWh) : "\u{2014}", kind: .calculated)
            row("Time measured", Self.duration(stats.measuredSeconds))
            Text(Settings.shared.recordHistory
                 ? "Computed from 5-second samples. Gaps (sleep, source dropouts) are not counted."
                 : "History recording is off, so no session statistics are collected.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassSurface()
    }

    private var flowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Power flow", systemImage: "arrow.triangle.branch").font(.headline)
            let scale = Scale(panelWidth: Settings.panelWidth)
            SankeyView(snapshot: s, s: scale)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.12)))
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity)
            Text("Ribbon thickness is proportional to watts. The machine node is derived as adapter minus battery, so the ribbons balance by construction; component power (GPU, CPU) is not drawn because it does not sum to the total.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
    }

    private func row(_ k: String, _ v: String, kind: MeasurementKind? = nil) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            if let kind { KindBadge(kind: kind) }
            Spacer()
            Text(v).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    static func duration(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        if t < 60 { return "\(t) s" }
        if t < 3600 { return "\(t / 60) min" }
        return "\(t / 3600) h \((t % 3600) / 60) min"
    }
}

// MARK: - History

struct HistoryTab: View {
    @ObservedObject var monitor: PowerMonitor
    @ObservedObject var settings: Settings
    @State private var range: Range = .hour
    @State private var samples: [HistorySample] = []
    @State private var shown: Set<Series> = [.load, .adapter, .battery]
    @State private var confirmDelete = false
    @State private var errorText: String?

    enum Range: String, CaseIterable, Identifiable {
        case quarter = "15 min", hour = "1 hour", sixHours = "6 hours", day = "24 hours", week = "7 days"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .quarter: return 900
            case .hour: return 3600
            case .sixHours: return 6 * 3600
            case .day: return 24 * 3600
            case .week: return 7 * 24 * 3600
            }
        }
    }

    enum Series: String, CaseIterable, Identifiable {
        case load = "System load", adapter = "Adapter input", battery = "Battery",
             pstr = "System total (PSTR)", gpu = "GPU"
        var id: String { rawValue }
        var kind: MeasurementKind {
            switch self {
            case .load, .battery: return .calculated
            case .adapter, .pstr, .gpu: return .direct
            }
        }
        func value(_ s: HistorySample) -> Double? {
            switch self {
            case .load: return s.systemLoadWatts
            case .adapter: return s.adapterWatts
            case .battery: return s.batteryWatts
            case .pstr: return s.smcSystemTotalWatts
            case .gpu: return s.gpuWatts
            }
        }
    }

    private struct LoadKey: Equatable { var range: Range; var tick: Int }
    private var loadKey: LoadKey {
        // Short ranges follow every sample; long ranges re-read the file about
        // every two and a half minutes.
        LoadKey(range: range, tick: range.seconds <= 3600 ? monitor.historyRevision : monitor.historyRevision / 30)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                chartCard
                statsCard
                actions
            }
            .padding(20)
        }
        .task(id: loadKey) { await reload() }
        .confirmationDialog("Delete all stored power history?", isPresented: $confirmDelete) {
            Button("Delete History", role: .destructive) {
                do { try monitor.deleteHistory(); samples = [] } catch { errorText = error.localizedDescription }
            }
        } message: {
            Text("This removes the history file from this Mac. It cannot be undone.")
        }
        .alert("Couldn\u{2019}t complete that", isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } }
        )) { Button("OK") { errorText = nil } } message: { Text(errorText ?? "") }
    }

    private var controls: some View {
        HStack {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            Spacer()
            Menu {
                ForEach(Series.allCases) { item in
                    Toggle(item.rawValue, isOn: Binding(
                        get: { shown.contains(item) },
                        set: { on in if on { shown.insert(item) } else { shown.remove(item) } }
                    ))
                }
            } label: { Label("Series", systemImage: "line.3.horizontal.decrease") }
            .fixedSize()
        }
    }

    private var chartCard: some View {
        let now = Date()
        let lines = lineData()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Power over time").font(.headline)
                Spacer()
                Text("Gaps are left blank, never filled in").font(.caption).foregroundStyle(.secondary)
            }
            if lines.isEmpty {
                ContentUnavailableView(
                    settings.recordHistory ? "No samples in this range yet" : "History recording is off",
                    systemImage: "chart.xyaxis.line",
                    description: Text(settings.recordHistory
                        ? "Samples are recorded every 5 seconds while PowerFlow is running."
                        : "Turn on Record History from the menu bar item\u{2019}s right-click menu.")
                )
                .frame(height: 260)
            } else {
                Chart {
                    ForEach(lines) { line in
                        ForEach(Array(line.points.enumerated()), id: \.offset) { _, p in
                            LineMark(
                                x: .value("Time", p.date),
                                y: .value("Watts", p.value),
                                series: .value("Segment", line.id)
                            )
                            .foregroundStyle(by: .value("Series", line.series.rawValue))
                            .interpolationMethod(.linear)
                        }
                    }
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.3))
                }
                .chartXScale(domain: now.addingTimeInterval(-range.seconds)...now)
                .chartYAxisLabel("W")
                .chartLegend(position: .bottom)
                .frame(height: 280)
                .accessibilityLabel("Line chart of power in watts over the last \(range.rawValue)")
            }
        }
        .padding(14)
        .glassSurface()
    }

    private struct Line: Identifiable {
        let id: String
        let series: Series
        let points: [(date: Date, value: Double)]
    }

    private func lineData() -> [Line] {
        let bucket = max(Double(Int(PowerMonitor.recordInterval)), range.seconds / 500)
        var out: [Line] = []
        for series in Series.allCases where shown.contains(series) {
            let segs = HistorySeries.segments(
                samples, value: series.value, maxGap: PowerMonitor.recordInterval * 3
            )
            for (i, seg) in segs.enumerated() {
                let d = bucket > PowerMonitor.recordInterval ? seg.decimated(bucket: bucket) : seg
                // A single isolated point draws nothing as a line; keep it
                // visible as a zero-length segment rather than dropping it.
                let pts = d.points.count == 1 ? d.points + d.points : d.points
                out.append(Line(id: "\(series.rawValue)-\(i)", series: series, points: pts))
            }
        }
        return out
    }

    private var statsCard: some View {
        let stats = PowerStatistics.compute(samples)
        let coverage = min(1, stats.measuredSeconds / range.seconds)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("System load in this range").font(.headline)
                KindBadge(kind: .calculated)
            }
            HStack(spacing: 24) {
                stat("Average", watts(stats.averageWatts))
                stat("Peak", watts(stats.peakWatts))
                stat("Lowest", watts(stats.minimumWatts))
                stat("Energy", stats.sampleCount > 1 ? String(format: "%.2f Wh", stats.energyWh) : "\u{2014}")
                stat("Coverage", String(format: "%.0f%%", coverage * 100))
            }
            Text("Energy and coverage count only time between consecutive samples; sleep and other gaps are excluded, so energy is not extrapolated across them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack {
            Toggle("Record history", isOn: $settings.recordHistory)
            Spacer()
            Button {
                HistoryActions.export(monitor: monitor, since: Date().addingTimeInterval(-range.seconds)) { errorText = $0 }
            } label: { Label("Export \(range.rawValue) as CSV\u{2026}", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Delete History\u{2026}", systemImage: "trash")
            }
        }
    }

    private func reload() async {
        let since = Date().addingTimeInterval(-range.seconds)
        if range.seconds <= 3600 {
            samples = monitor.recent.filter { $0.timestamp >= since }
            return
        }
        monitor.history.flush()
        let url = monitor.history.fileURL
        let loaded = await Task.detached(priority: .utility) {
            HistoryStore.readFile(url, since: since)
        }.value
        if !Task.isCancelled { samples = loaded }
    }
}

/// Export/delete flows shared by the dashboard and the status-item menu.
@MainActor
enum HistoryActions {
    static func export(monitor: PowerMonitor, since: Date?, onError: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "PowerFlow-history-\(f.string(from: Date())).csv"
        panel.title = "Export Power History"
        panel.message = "Exports the recorded samples as CSV. Empty cells mean the value was not measured."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { _ = try monitor.history.export(to: url, since: since) }
        catch HistoryError.destinationIsStorageFile {
            onError("Choose a different file: that one is PowerFlow\u{2019}s own history log.")
        } catch { onError(error.localizedDescription) }
    }

    static func confirmAndDelete(monitor: PowerMonitor) {
        let alert = NSAlert()
        alert.messageText = "Delete all stored power history?"
        alert.informativeText = "This removes the history file from this Mac. It cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete History")
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try monitor.deleteHistory() } catch {
            let e = NSAlert(error: error); e.runModal()
        }
    }
}

// MARK: - Apps

struct AppsTab: View {
    @ObservedObject var monitor: PowerMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Energy attributed to apps").font(.headline)
                    KindBadge(kind: .estimated)
                }
                Text("These are the kernel\u{2019}s per-process CPU energy counters divided by elapsed time. They are an attribution, not a power measurement: they capture roughly half of real power, skip root-owned processes (including WindowServer), and leave out the display and GPU. They do not add up to the system load.")
                    .font(.callout).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(monitor.rows) { row in
                        HStack(spacing: 10) {
                            if let icon = row.icon {
                                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                            } else {
                                Image(systemName: row.isSystem ? "questionmark.circle" : "app.dashed")
                                    .frame(width: 22, height: 22).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(row.name).lineLimit(1)
                                if row.isSystem {
                                    Text("System load minus everything attributed above. Includes display, GPU, root-owned daemons and the unbilled half of app power.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(String(format: "%.2f W", row.watts)).monospacedDigit()
                                .foregroundStyle(row.isSystem ? Color.secondary : Color.primary)
                            KindBadge(kind: row.isSystem ? .calculated : .estimated)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .accessibilityElement(children: .combine)
                        if row.id != monitor.rows.last?.id { Divider().padding(.leading, 46) }
                    }
                    if monitor.rows.isEmpty {
                        Text("Measuring\u{2026} app energy appears after the second sample (about 3 seconds).")
                            .foregroundStyle(.secondary).padding(14)
                    }
                }
                .glassSurface()
            }
            .padding(20)
        }
    }
}

// MARK: - Sources

struct SourcesTab: View {
    @ObservedObject var monitor: PowerMonitor

    var body: some View {
        let items = MeasurementCatalog.descriptors(
            hasLiveSMC: monitor.snapshot.dataSource == .smc,
            hasSystemTotal: monitor.snapshot.smcSystemTotal != nil,
            components: monitor.components
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Where every number comes from").font(.headline)
                Text("Direct values are reported by a system interface. Calculated values are arithmetic on direct ones. Estimated values come from a model. Unavailable means this Mac does not expose it, and PowerFlow shows no number rather than inventing one.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.name).font(.subheadline.weight(.semibold))
                            KindBadge(kind: item.kind)
                            Spacer()
                            Text(item.source).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.note).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface(cornerRadius: 12)
                    .accessibilityElement(children: .combine)
                }
                Text("Live figures on the Live tab are lightly smoothed (35% weight on each new reading). Recorded history stores the raw readings, one every 5 seconds, and records a sample as missing when a sensor dropout had to be papered over.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}
