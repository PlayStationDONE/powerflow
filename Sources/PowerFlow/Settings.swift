import Foundation
import PowerFlowKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// User-adjustable state, persisted in `UserDefaults`.
///
/// A note on the two markers: macOS exposes no public API for setting a
/// hardware charge limit — apps that enforce one write SMC registers through a
/// privileged root helper. This app deliberately does not do that. The handle
/// and the dashed line are *charge markers*: you set where you want the pack to
/// sit, the panel shows your charge against them, and the app tells you when
/// they are crossed. Nothing here changes how the Mac charges.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    static let panelWidth: CGFloat = 340

    @Published var chargeTarget: Double {
        didSet { defaults.set(chargeTarget, forKey: "chargeTarget") }
    }
    @Published var resumeFloor: Double {
        didSet { defaults.set(resumeFloor, forKey: "resumeFloor") }
    }
    /// Whether the user has been asked about notifications yet.
    private var askedForNotifications: Bool {
        get { defaults.bool(forKey: "askedForNotifications") }
        set { defaults.set(newValue, forKey: "askedForNotifications") }
    }

    /// What the menu-bar item shows. A crowded menu bar fills from the right
    /// edge leftward, and an item that does not fit is pushed past the notch
    /// into the app-menu area where it cannot be seen, so the default is the
    /// narrowest useful form.
    enum MenuBarStyle: String, CaseIterable {
        case iconOnly
        case iconAndPercent
        case iconAndWatts

        var title: String {
            switch self {
            case .iconOnly: return "Icon Only"
            case .iconAndPercent: return "Icon and Percentage"
            case .iconAndWatts: return "Icon and Watts"
            }
        }
    }

    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }

    /// Whether power history is written to disk. On by default; turning it off
    /// stops new rows but keeps what is already stored until deleted.
    @Published var recordHistory: Bool {
        didSet { defaults.set(recordHistory, forKey: "recordHistory") }
    }

    /// True: a normal app with a Dock tile and the dashboard window, plus the
    /// menu-bar item. False: menu-bar only.
    static var showInDockDefault: Bool {
        (UserDefaults.standard.object(forKey: "showInDock") as? Bool) ?? true
    }
    @Published var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: "showInDock") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        showInDock = Settings.showInDockDefault
        recordHistory = (UserDefaults.standard.object(forKey: "recordHistory") as? Bool) ?? true
        let t = defaults.double(forKey: "chargeTarget")
        let f = defaults.double(forKey: "resumeFloor")
        chargeTarget = t > 0 ? t : 0.80
        resumeFloor = f > 0 ? f : 0.75
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "")
            ?? .iconOnly
    }

    /// Markers are clamped so the floor always stays below the target.
    func setTarget(_ v: Double) {
        chargeTarget = min(1.0, max(0.20, v))
        if resumeFloor > chargeTarget - 0.02 { resumeFloor = max(0.05, chargeTarget - 0.02) }
        requestNotificationsOnce()
    }

    func setFloor(_ v: Double) {
        resumeFloor = min(chargeTarget - 0.02, max(0.05, v))
        requestNotificationsOnce()
    }

    /// Asked the first time a marker is actually moved, so a user who never
    /// touches them is never prompted.
    private func requestNotificationsOnce() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    // MARK: launch at login

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("PowerFlow: could not change login item: \(error)")
        }
    }
}

/// Watches the charge level and posts a notification when it crosses a marker.
@MainActor
final class MarkerWatcher {
    private var lastPercent: Double?

    func check(_ s: PowerSnapshotLike, settings: Settings) {
        defer { lastPercent = s.percent }
        guard let previous = lastPercent else { return }
        let target = settings.chargeTarget * 100
        let floor = settings.resumeFloor * 100

        if previous < target, s.percent >= target, s.externalConnected {
            notify("Charge target reached", "The battery is at \(Int(s.percent))%.")
        }
        if previous > floor, s.percent <= floor, !s.externalConnected {
            notify("Below your floor", "The battery has dropped to \(Int(s.percent))%.")
        }
    }

    private func notify(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            ))
        }
    }
}

/// Minimal surface the watcher needs, so it can be exercised without IOKit.
protocol PowerSnapshotLike {
    var percent: Double { get }
    var externalConnected: Bool { get }
}
extension PowerSnapshot: PowerSnapshotLike {}
