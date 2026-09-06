import AppKit
import PowerFlowKit
import SwiftUI

@main
enum PowerFlowMain {
    static func main() {
        let args = CommandLine.arguments

        // QA path: render the panel offscreen and exit, so the layout can be
        // diffed against the reference without a display session.
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            MainActor.assumeIsolated {
                Renderer.run(path: args[i + 1], args: args)
            }
            return
        }
        if args.contains("--smc") {
            guard let smc = SMCReader() else { print("no AppleSMC"); return }
            print("  PDTR(W)   B0AC(mA)  B0AV(mV)   battery(W)   derived load(W)")
            for _ in 0..<10 {
                let d = smc.double("PDTR") ?? .nan
                let a = smc.double("B0AC") ?? .nan
                let v = smc.double("B0AV") ?? .nan
                let b = v / 1000 * a / 1000
                print(String(format: "  %7.3f  %9.0f  %8.0f  %11.3f  %15.3f", d, a, v, b, d - b))
                Thread.sleep(forTimeInterval: 0.9)
            }
            return
        }
        if let i = args.firstIndex(of: "--animtest"), i + 1 < args.count {
            let dir = args[i + 1]
            let app = NSApplication.shared
            let d = AnimTestDelegate(dir: dir)
            app.delegate = d
            app.setActivationPolicy(.accessory)
            app.run()
            return
        }
        if let i = args.firstIndex(of: "--render-menubar"), i + 1 < args.count {
            let dir = args[i + 1]
            let app = NSApplication.shared
            let d = MenuBarShotDelegate(dir: dir)
            app.delegate = d
            app.setActivationPolicy(.accessory)
            app.run()
            return
        }
        if args.contains("--diagnose") {
            let app = NSApplication.shared
            let d = DiagnoseDelegate()
            app.delegate = d
            app.setActivationPolicy(.accessory)
            app.run()
            return
        }
        if args.contains("--sensorrate") {
            guard let smc = SMCReader() else { print("no SMC"); return }
            var last: Double = -1
            var changes: [TimeInterval] = []
            var lastChange = Date()
            let start = Date()
            while Date().timeIntervalSince(start) < 6 {
                if let v = smc.double("PDTR"), v != last {
                    if last >= 0 { changes.append(Date().timeIntervalSince(lastChange)) }
                    lastChange = Date()
                    last = v
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            let avg = changes.isEmpty ? 0 : changes.reduce(0, +) / Double(changes.count)
            print(String(format: "PDTR changed %d times in 6 s", changes.count))
            print(String(format: "mean interval between changes: %.0f ms (%.1f Hz)", avg * 1000, 1 / avg))
            print(String(format: "min %.0f ms   max %.0f ms",
                         (changes.min() ?? 0) * 1000, (changes.max() ?? 0) * 1000))
            return
        }
        if args.contains("--stability") {
            let reader = PowerReader()
            var anomalies = 0
            for i in 0..<60 {
                let smc = reader.readSMC()
                let src = PowerReader.readPowerSources()
                guard let snap = reader.read() else { continue }
                let bad = (snap.externalConnected && snap.adapterPower <= 0.01)
                    || (!snap.externalConnected && snap.adapterPower > 0.01)
                    || smc == nil
                if bad {
                    anomalies += 1
                    print(String(format: "  [%02d] ANOMALY ext=%@ adapter=%.2f load=%.2f smc=%@ src=%@",
                                 i, snap.externalConnected ? "Y" : "N", snap.adapterPower, snap.systemLoad,
                                 smc == nil ? "nil" : "ok",
                                 src == nil ? "nil" : (src!.externalConnected ? "AC" : "batt")))
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            print("anomalies in 60 samples: \(anomalies)")
            return
        }
        if args.contains("--apps") {
            MainActor.assumeIsolated { Renderer.apps() }
            return
        }
        if args.contains("--probe") {
            MainActor.assumeIsolated { Renderer.probe() }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar only: no Dock tile, no main menu.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - Status item + popover

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = PowerMonitor()
    private let markers = MarkerWatcher()
    private let anchor = AnchorWindow()
    private var observer: AnyObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        // The palette is a fixed dark one taken from the reference, so the
        // popover's material is pinned to dark too. Letting it follow the
        // system would put dark grey cards and white labels on a light
        // backdrop in Light Mode.
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.contentSize = NSSize(
            width: Settings.panelWidth,
            height: Scale(panelWidth: Settings.panelWidth).extendedPanelHeight
        )
        popover.contentViewController = NSHostingController(
            rootView: PanelRoot(monitor: monitor)
        )

        updateStatusLabel()

        // A full menu bar can leave the status item unreachable, so there is
        // always a keyboard way in.
        Hotkey.shared.register { [weak self] in self?.toggleFromHotkey() }

        // --selftest exercises the real popover: SwiftUI only builds a hosting
        // controller's view when it is actually shown, so an offscreen render
        // would not catch a failure on this path.
        if let i = CommandLine.arguments.firstIndex(of: "--filmstrip"),
           i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let button = self.statusItem.button else { exit(1) }
                self.togglePopover(button)
                var frame = 0
                Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
                    MainActor.assumeIsolated {
                        guard let view = self.popover.contentViewController?.view else { return }
                        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                            if let png = rep.representation(using: .png, properties: [:]) {
                                try? png.write(to: URL(fileURLWithPath: "\(dir)/f\(String(format: "%02d", frame)).png"))
                            }
                        }
                        frame += 1
                        if frame >= 20 { t.invalidate(); exit(0) }
                    }
                }
            }
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.statusItem.button != nil else { exit(1) }
                print("status item reachable: \(self.statusItemIsReachable)")
                print("hotkey registered:     \(Hotkey.shared.isRegistered)  (option-command-P)")
                self.toggleFromHotkey()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                    let shown = self.popover.isShown
                    guard let view = self.popover.contentViewController?.view else { exit(2) }
                    let size = view.frame.size
                    // Draw the live view into a bitmap. SwiftUI renders into
                    // layers rather than AppKit subviews, so capturing real
                    // pixels is the only honest proof that it drew anything.
                    var painted = false
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        painted = Self.hasContent(rep)
                        if let args = CommandLine.arguments.firstIndex(of: "--selftest"),
                           args + 1 < CommandLine.arguments.count,
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[args + 1]))
                        }
                    }
                    print("popover shown: \(shown)  size \(Int(size.width))x\(Int(size.height))")
                    print("live view drew pixels: \(painted)")
                    print("snapshot:      \(String(format: "%.2f W in, %.2f W load", self.monitor.snapshot.adapterPower, self.monitor.snapshot.systemLoad))")
                    exit(shown && painted ? 0 : 2)
                }
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: .powerSnapshotChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusLabel() }
        }
        // The monitor publishes on a timer; mirror it into the menu-bar label.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusLabel() }
        }
    }

    /// True when the bitmap contains more than one distinct colour, i.e. the
    /// view actually drew rather than handing back a blank buffer.
    static func hasContent(_ rep: NSBitmapImageRep) -> Bool {
        var seen = Set<UInt32>()
        let stepX = max(1, rep.pixelsWide / 40), stepY = max(1, rep.pixelsHigh / 40)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let key = UInt32(c.redComponent * 255) << 16
                    | UInt32(c.greenComponent * 255) << 8
                    | UInt32(c.blueComponent * 255)
                seen.insert(key)
                if seen.count > 6 { return true }
            }
        }
        return false
    }

    private func updateStatusLabel() {
        guard let button = statusItem.button else { return }
        let s = monitor.snapshot
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.image = NSImage(
            systemSymbolName: symbolName(for: s),
            accessibilityDescription: "Battery"
        )?.withSymbolConfiguration(config)
        switch Settings.shared.menuBarStyle {
        case .iconOnly:
            button.title = ""
        case .iconAndPercent:
            button.title = " \(Int(s.percent.rounded()))%"
        case .iconAndWatts:
            button.title = String(format: " %.0fW", s.systemLoad)
        }
        button.toolTip = tooltip(for: s)
        markers.check(s, settings: .shared)
    }

    private func symbolName(for s: PowerSnapshot) -> String {
        if s.isCharging { return "battery.100.bolt" }
        switch s.percent {
        case ..<10: return "battery.0"
        case ..<35: return "battery.25"
        case ..<60: return "battery.50"
        case ..<85: return "battery.75"
        default: return "battery.100"
        }
    }

    private func tooltip(for s: PowerSnapshot) -> String {
        var lines = [String(format: "System %.1f W", s.systemLoad)]
        if s.externalConnected {
            lines.append(String(format: "Adapter %.1f W", s.adapterPower))
        }
        if abs(s.batteryPower) > 0.01 {
            let verb = s.batteryPower > 0 ? "Charging" : "Discharging"
            lines.append(String(format: "%@ %.1f W", verb, abs(s.batteryPower)))
        }
        if let name = s.adapterName { lines.append(name) }
        return lines.joined(separator: "\n")
    }

    @objc private func setMenuBarStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = Settings.MenuBarStyle(rawValue: raw) else { return }
        Settings.shared.menuBarStyle = style
        updateStatusLabel()
    }

    @objc private func toggleLaunchAtLogin() {
        Settings.shared.setLaunchAtLogin(!Settings.shared.launchAtLogin)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.refresh()
            monitor.refreshApps()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        monitor.isPanelVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.isPanelVisible = false
    }

    /// True when the status item sits somewhere the user can actually click it.
    /// Items are laid out from the right edge leftward; once the row is full,
    /// the next one is pushed past the notch into the app-menu area, where the
    /// frontmost app's menus cover it.
    private var statusItemIsReachable: Bool {
        guard let window = statusItem.button?.window else { return false }
        guard let screen = NSScreen.main, let right = screen.auxiliaryTopRightArea else {
            return true   // no notch: nothing to be pushed behind
        }
        return window.frame.minX >= right.minX - 1
    }

    /// Opens the panel whether or not the menu-bar item can be seen.
    private func toggleFromHotkey() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        monitor.refresh()
        monitor.refreshApps()
        if statusItemIsReachable, let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            let view = anchor.view()
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        let menu = NSMenu()
        let s = monitor.snapshot
        if let name = s.adapterName {
            menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        if let health = s.health {
            menu.addItem(withTitle: String(format: "Health %.0f%%", health), action: nil, keyEquivalent: "")
        }
        if let cycles = s.cycleCount {
            menu.addItem(withTitle: "\(cycles) cycles", action: nil, keyEquivalent: "")
        }
        if let temp = s.temperature {
            menu.addItem(withTitle: String(format: "%.1f\u{00B0}C", temp), action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())

        let styleItem = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for style in Settings.MenuBarStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(setMenuBarStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = Settings.shared.menuBarStyle == style ? .on : .off
            styleMenu.addItem(item)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        if !statusItemIsReachable {
            let text = Hotkey.shared.isRegistered
                ? "Menu bar is full \u{2013} press \u{2325}\u{2318}P to open"
                : "Menu bar is full \u{2013} free a slot to see this item"
            let warning = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
        )
        login.target = self
        login.state = Settings.shared.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PowerFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}

extension Notification.Name {
    static let powerSnapshotChanged = Notification.Name("PowerFlow.snapshotChanged")
}

/// Wraps the panel so it re-renders whenever the monitor publishes.
struct PanelRoot: View {
    @ObservedObject var monitor: PowerMonitor
    @ObservedObject var settings = Settings.shared

    var body: some View {
        PanelView(
            snapshot: monitor.panelSnapshot,
            target: settings.chargeTarget,
            floor: settings.resumeFloor,
            panelWidth: Settings.panelWidth,
            rows: monitor.panelRows,
            runtimeText: monitor.panelRuntime,
            onTargetChange: { settings.setTarget($0) },
            onFloorChange: { settings.setFloor($0) }
        )
    }
}

// MARK: - Offscreen rendering for QA

@MainActor
enum Renderer {
    static func run(path: String, args: [String]) {
        let width = value(named: "--width", in: args) ?? 340
        let scale = value(named: "--scale", in: args) ?? (1266 / width)
        let snapshot: PowerSnapshot
        if args.contains("--live"), let live = PowerReader().read() {
            snapshot = live
        } else if let i = args.firstIndex(of: "--state"), i + 1 < args.count {
            switch args[i + 1] {
            case "charging": snapshot = .charging
            case "battery": snapshot = .onBattery
            case "full": snapshot = .full
            default: snapshot = .sample
            }
        } else {
            snapshot = .sample
        }

        // Rows: real ones for --live (two samples a few seconds apart), a fixed
        // set otherwise so QA renders are reproducible.
        var rows: [DrawRow] = Self.sampleRows(for: snapshot)
        var runtime = RuntimeEstimate.format(
            RuntimeEstimate.seconds(remainingWh: snapshot.remainingWh, load: snapshot.systemLoad)
        )
        if args.contains("--live") {
            let sampler = AppEnergySampler()
            _ = sampler.sample(appNames: RunningApps.names())
            Thread.sleep(forTimeInterval: 3.0)
            let measured = sampler.sample(appNames: RunningApps.names())
            let attributed = measured.reduce(0) { $0 + $1.watts }
            rows = measured.filter { $0.watts >= 0.05 }.prefix(Ref.appRowCount).map {
                DrawRow(id: $0.pid, name: $0.name, watts: $0.watts,
                        icon: RunningApps.icon(for: $0.pid), isSystem: false)
            }
            rows.append(DrawRow(id: -1, name: "System & display",
                                watts: max(0, snapshot.systemLoad - attributed),
                                icon: nil, isSystem: true))
            runtime = RuntimeEstimate.format(RuntimeEstimate.seconds(
                remainingWh: snapshot.remainingWh, load: snapshot.systemLoad))
        }

        let view = PanelView(
            snapshot: snapshot,
            target: Settings.shared.chargeTarget,
            floor: Settings.shared.resumeFloor,
            panelWidth: width,
            rows: rows,
            runtimeText: runtime,
            showsExtras: !args.contains("--reference-only")
        )
        .background(background(args: args))

        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) at \(Int(width * scale))px wide")
    }

    /// Stand-in rows so QA renders do not depend on what happens to be running.
    /// The apps are fixed; the remainder is computed from the state being drawn
    /// so a render never shows a 94 W system row under a 14 W load.
    static func sampleRows(for snapshot: PowerSnapshot) -> [DrawRow] {
        let apps = [
            DrawRow(id: 1, name: "Google Chrome", watts: 6.4, icon: nil, isSystem: false),
            DrawRow(id: 2, name: "Xcode", watts: 3.1, icon: nil, isSystem: false),
            DrawRow(id: 3, name: "Slack", watts: 1.2, icon: nil, isSystem: false),
            DrawRow(id: 4, name: "Music", watts: 0.4, icon: nil, isSystem: false),
        ]
        let scale = min(1, snapshot.systemLoad / 40)
        let scaled = apps.map {
            DrawRow(id: $0.id, name: $0.name, watts: ($0.watts * scale * 10).rounded() / 10,
                    icon: nil, isSystem: false)
        }
        let attributed = scaled.reduce(0) { $0 + $1.watts }
        return scaled + [DrawRow(id: -1, name: "System & display",
                                 watts: max(0, snapshot.systemLoad - attributed),
                                 icon: nil, isSystem: true)]
    }

    /// The popover material is not available offscreen, so approximate the
    /// translucent backdrop with the flat colour it resolves to over a dark
    /// desktop. Only used for QA renders.
    private static func background(args: [String]) -> Color {
        Color(red: 44 / 255, green: 45 / 255, blue: 53 / 255)
    }

    /// Samples per-app watts alongside the machine's total, so the two can be
    /// compared directly.
    static func apps() {
        let sampler = AppEnergySampler()
        let reader = PowerReader()
        _ = sampler.sample(appNames: RunningApps.names())
        var worst = 0.0
        for _ in 0..<5 {
            let t0 = Date()
            _ = AppEnergySampler.readAll()
            worst = max(worst, Date().timeIntervalSince(t0))
        }
        print(String(format: "process enumeration: worst of 5 = %.1f ms (%d processes)",
                     worst * 1000, AppEnergySampler.readAll().count))
        for round in 0..<3 {
            Thread.sleep(forTimeInterval: 3.0)
            let rows = sampler.sample(appNames: RunningApps.names())
            let total = reader.read()?.systemLoad ?? .nan
            let sum = rows.reduce(0) { $0 + $1.watts }
            print(String(format: "\n--- round %d   system %.2f W   apps %.2f W (%.0f%%)",
                         round + 1, total, sum, sum / total * 100))
            for r in rows.prefix(8) {
                print(String(format: "    %-30@ %6.3f W", r.name as NSString, r.watts))
            }
        }
    }

    static func probe() {
        let reader = PowerReader()
        guard let s = reader.read() else {
            print("no battery")
            return
        }
        print(String(format: "percent      %.1f%%", s.percent))
        print("external     \(s.externalConnected)")
        print("charging     \(s.isCharging)  paused \(s.chargingPaused)  full \(s.fullyCharged)")
        print(String(format: "adapter      %.2f W", s.adapterPower))
        print(String(format: "battery      %+.2f W", s.batteryPower))
        print(String(format: "system load  %.2f W", s.systemLoad))
        print(String(format: "check        adapter - battery = %.2f", s.adapterPower - s.batteryPower))
        if let w = s.adapterWatts { print("adapter rated \(w) W  \(s.adapterName ?? "")") }
        if let h = s.health { print(String(format: "health       %.1f%%", h)) }
        print("live SMC     \(reader.hasLivePower)")
        if let r = s.remainingWh, let f = s.fullWh {
            print(String(format: "pack         %.1f Wh of %.1f Wh", r, f))
        }
        let secs = RuntimeEstimate.seconds(remainingWh: s.remainingWh, load: s.systemLoad)
        print("if unplugged \(RuntimeEstimate.format(secs) ?? "unknown") at this instant's load")
    }

    private static func value(named: String, in args: [String]) -> CGFloat? {
        guard let i = args.firstIndex(of: named), i + 1 < args.count,
              let v = Double(args[i + 1]) else { return nil }
        return CGFloat(v)
    }
}


/// Reports where the status item actually ends up, for when it does not appear.
@MainActor
final class DiagnoseDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: nil)
        item.button?.title = CommandLine.arguments.contains("--wide") ? " 100%" : ""
        item.button?.imagePosition = .imageLeading

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let screen = NSScreen.main
            print("statusItem.isVisible : \(self.item.isVisible)")
            print("statusItem.length    : \(self.item.length)")
            if let b = self.item.button {
                print("button.frame         : \(b.frame)")
                print("button.window.frame  : \(String(describing: b.window?.frame))")
                print("button.image         : \(b.image == nil ? "nil" : "set")  title \"\(b.title)\"")
            } else {
                print("button               : nil")
            }
            if let s = screen {
                print("screen.frame         : \(s.frame)")
                print("menu bar height      : \(s.frame.height - s.visibleFrame.height - s.visibleFrame.origin.y)")
                if #available(macOS 12.0, *) {
                    print("safeAreaInsets(top)  : \(s.safeAreaInsets.top)   <- non-zero means a notch")
                    print("auxiliaryTopLeftArea : \(String(describing: s.auxiliaryTopLeftArea))")
                    print("auxiliaryTopRightArea: \(String(describing: s.auxiliaryTopRightArea))")
                }
            }
            exit(0)
        }
    }
}


/// Two states with the same topology - adapter and battery both feeding the
/// machine - so the ribbons change thickness instead of appearing and
/// disappearing.
enum AnimFixture {
    static let before = PowerSnapshot(
        percent: 79, externalConnected: true, chargingPaused: true,
        adapterPower: 87.77, batteryPower: -16.92, systemLoad: 104.69,
        remainingWh: 55.4, fullWh: 70.1
    )
    static let after = PowerSnapshot(
        percent: 79, externalConnected: true, chargingPaused: true,
        adapterPower: 30.0, batteryPower: -60.0, systemLoad: 90.0,
        remainingWh: 55.4, fullWh: 70.1
    )
}

/// Records the value SwiftUI hands it on every animation frame. `cacheDisplay`
/// renders the model layer rather than the presentation layer, so pixels cannot
/// show an animation in flight; the interpolated `animatableData` can.
struct FrameRecorder: ViewModifier, Animatable {
    var value: CGFloat
    static var samples: [(TimeInterval, CGFloat)] = []
    static var start = Date()

    var animatableData: CGFloat {
        get { value }
        set {
            value = newValue
            Self.samples.append((Date().timeIntervalSince(Self.start), newValue))
        }
    }

    func body(content: Content) -> some View { content }
}

/// Drives the real panel between two readings of the same shape and captures
/// frames, so the ribbons' interpolation can be measured rather than assumed.
@MainActor
final class AnimTestDelegate: NSObject, NSApplicationDelegate {
    private let dir: String
    private var window: NSWindow!
    private var model = AnimModel()

    init(dir: String) { self.dir = dir }


    final class AnimModel: ObservableObject {
        @Published var snapshot = AnimFixture.before
    }

    struct Root: View {
        @ObservedObject var model: AnimModel
        var body: some View {
            PanelView(snapshot: model.snapshot, panelWidth: 340,
                      rows: [], runtimeText: "1h 00m", showsExtras: false)
                .background(Color(red: 44 / 255, green: 45 / 255, blue: 53 / 255))
                .modifier(FrameRecorder(value: model.snapshot.adapterPower))
                .animation(Motion.flow, value: model.snapshot)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let height = Scale(panelWidth: 340).panelHeight
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Root(model: model))
        window.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            FrameRecorder.samples.removeAll()
            FrameRecorder.start = Date()
            self.model.snapshot = AnimFixture.after
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let s = FrameRecorder.samples
            print("interpolated frames: \(s.count)")
            if let first = s.first, let last = s.last {
                print(String(format: "span: %.2f s   %.2f W -> %.2f W",
                             last.0 - first.0, first.1, last.1))
            }
            let gaps = zip(s, s.dropFirst()).map { $1.0 - $0.0 }
            if !gaps.isEmpty {
                let avg = gaps.reduce(0, +) / Double(gaps.count)
                print(String(format: "mean gap: %.1f ms  (%.0f fps)   worst gap: %.1f ms",
                             avg * 1000, 1 / avg, (gaps.max() ?? 0) * 1000))
            }
            let vals = s.map { $0.1 }
            let monotonic = zip(vals, vals.dropFirst()).allSatisfy { $1 <= $0 + 0.001 }
            print("monotonic (no overshoot): \(monotonic)")
            if let first = s.first?.1, let target = s.last?.1 {
                let total = target - first
                func timeTo(_ pct: Double) -> String {
                    guard let hit = s.first(where: { abs($0.1 - first) >= abs(total) * pct })
                    else { return "n/a" }
                    return String(format: "%.0f ms", (hit.0 - s[0].0) * 1000)
                }
                print("time to 50%: \(timeTo(0.5))   90%: \(timeTo(0.9))   99%: \(timeTo(0.99))")
            }
            print("first 6:", s.prefix(6).map { String(format: "%.1f", $0.1) }.joined(separator: " "))
            exit(0)
        }
    }
}


/// Renders the real status-item button in each label style.
///
/// The menu bar itself cannot be screenshotted without Screen Recording
/// permission, and on a full menu bar the item is hidden behind the notch
/// anyway - but the button is a real view and can draw itself.
@MainActor
final class MenuBarShotDelegate: NSObject, NSApplicationDelegate {
    private let dir: String
    private var item: NSStatusItem!
    init(dir: String) { self.dir = dir }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { exit(1) }
        // The menu bar is dark here, so template art draws light.
        button.appearance = NSAppearance(named: .darkAqua)
        button.imagePosition = .imageLeading

        let snapshot = PowerReader().read() ?? .sample
        let styles: [(String, String)] = [
            ("iconOnly", ""),
            ("iconAndPercent", " \(Int(snapshot.percent.rounded()))%"),
            ("iconAndWatts", String(format: " %.0fW", snapshot.systemLoad)),
        ]
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.image = NSImage(systemSymbolName: "battery.100",
                               accessibilityDescription: "Battery")?
            .withSymbolConfiguration(config)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            for (name, title) in styles {
                button.title = title
                button.sizeToFit()
                button.layoutSubtreeIfNeeded()
                button.display()
                guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds)
                else { continue }
                button.cacheDisplay(in: button.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(self.dir)/menubar-\(name).png"))
                }
                print(String(format: "%@: %.0f x %.0f pt", name,
                             button.bounds.width, button.bounds.height))
            }
            exit(0)
        }
    }
}
