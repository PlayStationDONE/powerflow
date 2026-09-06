import AppKit
import PowerFlowKit

/// Maps process ids to the user-facing applications that own them.
///
/// Helper processes (renderers, GPU helpers, XPC services) are not running
/// applications, so they get folded into whichever ancestor is, which is what
/// turns twenty browser helpers into one row.
enum RunningApps {
    static func names() -> [Int32: String] {
        var out: [Int32: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier > 0 else { continue }
            out[app.processIdentifier] = app.localizedName ?? app.bundleIdentifier ?? "App"
        }
        return out
    }

    /// Icon for a pid, when it belongs to a running application.
    static func icon(for pid: Int32) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}
