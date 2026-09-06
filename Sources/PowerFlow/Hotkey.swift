import AppKit
import Carbon.HIToolbox

/// A single global hotkey, registered through Carbon so it needs no
/// accessibility permission.
///
/// This exists because a full menu bar can swallow the status item entirely:
/// macOS lays items out from the right edge leftward, and once the row is full
/// the next one is pushed past the notch into the app-menu area, where it is
/// covered by whatever app is frontmost. The hotkey is a way in that does not
/// depend on the item being reachable.
@MainActor
final class Hotkey {
    static let shared = Hotkey()

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// Option-Command-P by default.
    /// True once the system has actually granted the combination. It can fail
    /// if another app already owns it.
    private(set) var isRegistered = false

    @discardableResult
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_P),
                  modifiers: UInt32 = UInt32(optionKey | cmdKey),
                  action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            if id.id == 1 {
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.shared.fire() } }
            }
            return noErr
        }, 1, &spec, nil, &handler)

        let id = EventHotKeyID(signature: OSType(0x50_46_4C_57), id: 1)   // 'PFLW'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        isRegistered = status == noErr && ref != nil
        if !isRegistered { NSLog("PowerFlow: hotkey unavailable (status \(status))") }
        return isRegistered
    }

    fileprivate func fire() { action?() }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        isRegistered = false
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

/// A 1x1 invisible window used to anchor the popover when the status item is
/// not somewhere the user can actually see.
@MainActor
final class AnchorWindow {
    private var window: NSWindow?

    /// Places the anchor just under the menu bar at the top right of the main
    /// screen, inside the area that is not hidden by a notch.
    func view() -> NSView {
        let screen = NSScreen.main
        let right = screen?.auxiliaryTopRightArea ?? screen?.frame ?? .zero
        let x = right.maxX - 24
        let y = (screen?.frame.maxY ?? 0) - (screen?.safeAreaInsets.top ?? 24) - 2

        let w = window ?? {
            let panel = NSPanel(
                contentRect: NSRect(x: x, y: y, width: 1, height: 1),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window = panel
            return panel
        }()
        w.setFrameOrigin(NSPoint(x: x, y: y))
        w.orderFrontRegardless()
        return w.contentView!
    }
}
