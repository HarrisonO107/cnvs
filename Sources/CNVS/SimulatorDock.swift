import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// Which Space (desktop) a window lives on. macOS exposes this only through
/// private SkyLight symbols, and there is no way — public or private — to
/// *move* another app's window between Spaces: `CGSMoveWindowsToManagedSpace`
/// is inert without SIP disabled, and a minimize/restore bounce keeps the
/// original assignment (both verified 2026-08-02). Read-only is enough
/// though: knowing the device window is stranded on another desktop is what
/// turns a permanent "waiting for device window…" into a fixable state.
private enum Spaces {
    typealias ConnectionID = UInt32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static let connection: ConnectionID? = {
        guard let handle, let sym = dlsym(handle, "_CGSDefaultConnection") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> ConnectionID).self)()
    }()

    private static let copySpaces: (@convention(c) (ConnectionID, Int32, CFArray) -> CFArray?)? = {
        guard let handle, let sym = dlsym(handle, "CGSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (ConnectionID, Int32, CFArray) -> CFArray?).self)
    }()

    /// Empty when the symbols are missing (a future macOS renames them) — the
    /// caller treats that as "can't tell" and carries on rather than blocking.
    static func spaces(of window: CGWindowID) -> Set<Int> {
        guard let connection, let copySpaces else { return [] }
        let ids = copySpaces(connection, 7 /* all spaces */, [NSNumber(value: window)] as CFArray)
        return Set(((ids as? [NSNumber]) ?? []).map(\.intValue))
    }
}

/// Docks the real Simulator.app device window on top of a CNVS card by
/// pushing its frame (Accessibility API) to match the card's frame on
/// screen. Not true embedding — Apple exposes no cross-process view API —
/// but visually indistinguishable once parked, and fully interactive since
/// it's the real window.
@MainActor
final class SimulatorDockController: ObservableObject {
    enum Status: Equatable {
        case locating
        case needsPermission
        case notRunning
        case noWindow
        /// Device window exists but on a different desktop. Its own state
        /// because it's unfixable by waiting — and because activating
        /// Simulator here would yank the user off CNVS's desktop.
        case otherSpace
        case docked
    }

    static let shared = SimulatorDockController()

    @Published private(set) var status: Status = .locating

    /// The device window's size. Simulator rejects every programmatic resize
    /// (AX size sets fail with kAXErrorFailure at any size, aspect-correct or
    /// not — its zoom menu is the only way in), so the card sizes itself to
    /// the phone rather than the other way round.
    @Published private(set) var deviceSize: CGSize?

    private var axWindow: AXUIElement?
    private var pollTimer: Timer?
    private let bundleID = "com.apple.iphonesimulator"
    /// Hidden by a card close and still flagged Stay On Top.
    private var stowed = false

    /// Set while some other CNVS card is fullscreen. The docked window is a
    /// real OS window kept Stay On Top (see `dock(to:)`/`setStayOnTop`), so no
    /// amount of SwiftUI z-ordering inside CNVS can cover it — `refresh()`
    /// must be blocked from re-docking/raising it until this drops, or it
    /// floats back over whatever card is trying to fill the screen.
    var suppressed = false

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.iphonesimulator" else { return }
            MainActor.assumeIsolated { SimulatorDockController.shared.simulatorDidActivate() }
        }
    }

    /// Simulator brought forward while the card is closed — it's about to be
    /// back on screen and still set to float over everything, so drop that
    /// now. The timing is free: being active is the one condition the menu
    /// press needs, and here it's already met.
    private func simulatorDidActivate() {
        guard stowed else { return }
        stowed = false
        releaseStayOnTop()
    }

    /// Adopts a device window left floating by a previous run. Quitting CNVS
    /// with the phone stowed leaves Stay On Top ticked and nothing around to
    /// untick it, so the next time Simulator is opened it sits over every
    /// other app. Claiming it here hands it to the activation hook above.
    ///
    /// Only when no simulator card is open — with a card, the dock wants the
    /// window floating and will re-tick it anyway.
    func adoptStrayFloatingWindow(cardOpen: Bool) {
        guard !cardOpen,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
              let window = deviceWindow(pid: app.processIdentifier), window.isFloating
        else { return }
        stowed = true
        // Already frontmost, so no activation is coming to trigger the hook.
        if app.isActive { simulatorDidActivate() }
    }

    /// `AXIsProcessTrustedWithOptions` (the *prompting* variant) segfaults
    /// inside CFGetTypeID for this ad-hoc-signed, unnotarized build —
    /// reproduced 3x, independent of the dictionary's value type. Stick to
    /// the plain, argument-free trust check and send the user to System
    /// Settings ourselves instead of letting AX drive the prompt.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    func launchIfNeeded() {
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID })
        else { startPolling(); return }
        let candidates = [
            "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app",
            "/Applications/Simulator.app",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            status = .notRunning
            return
        }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: NSWorkspace.OpenConfiguration()
        )
        startPolling()
    }

    /// Looks for the device window. Call after launch and whenever nothing's
    /// found yet — the window mounts a beat after the process does. Also the
    /// only place that re-checks Accessibility trust, so the polling loop
    /// naturally picks up a grant made in System Settings without CNVS
    /// needing a live notification for it.
    func refresh() {
        guard !suppressed else { return }
        guard AXIsProcessTrusted() else {
            status = .needsPermission
            axWindow = nil
            startPolling()
            return
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
        else {
            status = .notRunning
            axWindow = nil
            return
        }
        // Card reopened after a stow. Unhiding first means everything below
        // measures a window that's actually on screen, and clearing the flag
        // before that stops the activation hook from unticking Stay On Top
        // when `setStayOnTop` brings Simulator forward a moment later.
        if app.isHidden {
            stowed = false
            app.unhide()
        }

        // The window list, unlike Accessibility, sees every Space — so it's
        // what settles "does the window exist at all" before we ask AX, which
        // would otherwise report an empty window array and read as "still
        // launching" forever.
        guard let device = deviceWindow(pid: app.processIdentifier) else {
            status = .noWindow
            axWindow = nil
            startPolling()
            return
        }
        let deviceSpaces = Spaces.spaces(of: device.id)
        let ownSpaces = ownSpaces()
        if !deviceSpaces.isEmpty, !ownSpaces.isEmpty, deviceSpaces.isDisjoint(with: ownSpaces) {
            NSLog("simdock: device window on space %{public}@, CNVS on %{public}@",
                  String(describing: deviceSpaces), String(describing: ownSpaces))
            status = .otherSpace
            axWindow = nil
            startPolling()
            return
        }

        guard let chosen = axDeviceWindow(of: app.processIdentifier) else {
            status = .noWindow
            axWindow = nil
            startPolling()
            return
        }
        // A window macOS put in its own fullscreen Space can't be docked and
        // would strand us in .otherSpace on the next pass — drop it back to a
        // normal window while we still have a handle on it.
        AXUIElementSetAttributeValue(chosen, "AXFullScreen" as CFString, kCFBooleanFalse)
        // May be minimized from an earlier card close — surface it again.
        AXUIElementSetAttributeValue(chosen, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        axWindow = chosen
        var size = CGSize.zero
        if let v = attr(chosen, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue((v as! AXValue), .cgSize, &size)
        }
        if size != .zero, size != deviceSize {
            deviceSize = size
            NotificationCenter.default.post(name: .cnvsSimulatorSized, object: nil)
        }
        setStayOnTop(true, pid: app.processIdentifier)
        status = .docked
        stopPolling()
    }

    /// Simulator's device window as an Accessibility element.
    ///
    /// `AXWindows` is the documented route but comes back EMPTY for Simulator
    /// in some states (verified 2026-08-02 — empty array, `.success` error
    /// code, while the window was alive on another Space), so fall back to the
    /// app's main/focused window, which still resolves. Both are checked for
    /// the standard subrole because Simulator also owns panels and toolbars.
    private func axDeviceWindow(of pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

        // The device window is the largest standard window; `windows.first`
        // grabs whatever z-order put on top.
        var best: (win: AXUIElement, area: CGFloat)?
        for win in (windowsRef as? [AXUIElement]) ?? [] {
            guard (attr(win, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole as String
            else { continue }
            var size = CGSize.zero
            if let v = attr(win, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
                AXValueGetValue((v as! AXValue), .cgSize, &size)
            }
            let area = size.width * size.height
            if best == nil || area > best!.area { best = (win, area) }
        }
        if let chosen = best?.win { return chosen }

        for fallback in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            guard let ref = attr(axApp, fallback) else { continue }
            let win = ref as! AXUIElement
            guard (attr(win, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole as String
            else { continue }
            return win
        }
        return nil
    }

    /// The device window as the global window list sees it. Its layer is how
    /// we read Stay On Top back: Simulator's menu item doesn't refresh its
    /// checkmark unless the menu is opened, but a floating window shows up
    /// above layer 0 immediately.
    struct DeviceWindow {
        let id: CGWindowID
        let layer: Int
        var isFloating: Bool { layer > 0 }
    }

    /// Biggest window Simulator owns. The menu-bar-sized strips it also owns
    /// are filtered out by size, and the small companion panels lose on area.
    /// Deliberately not filtered to layer 0 — Stay On Top raises the device
    /// window's layer, and excluding it would read as "no window" the moment
    /// we ticked the thing ourselves.
    private func deviceWindow(pid: pid_t) -> DeviceWindow? {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: (window: DeviceWindow, area: CGFloat)?
        for window in list {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer < 20,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let width = bounds["Width"] ?? 0, height = bounds["Height"] ?? 0
            guard width > 150, height > 300 else { continue }
            let area = width * height
            if best == nil || area > best!.area {
                best = (DeviceWindow(id: CGWindowID(number), layer: layer), area)
            }
        }
        return best?.window
    }

    /// Simulator's own Window ▸ Stay On Top, driven through its menu bar —
    /// there's no other way to raise another app's window above ours, and
    /// without it a docked phone disappears behind CNVS on the next click.
    ///
    /// State comes from the window's layer rather than the menu item's
    /// checkmark: `AXMenuItemMarkChar` doesn't update until the menu is
    /// actually opened, so reading it would flip the setting the wrong way.
    private func setStayOnTop(_ wanted: Bool, pid: pid_t) {
        guard let window = deviceWindow(pid: pid), window.isFloating != wanted,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })
        else { return }
        // Pressing the item while Simulator is in the background reports
        // success and does nothing — AppKit routes menu actions through the
        // active app. So activate first, press a beat later, and hand focus
        // back to CNVS if we're only tidying up on the way out.
        guard app.isActive else {
            app.activate(options: [])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                pressStayOnTop(wanted, pid: pid)
                guard !wanted else { return }
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        pressStayOnTop(wanted, pid: pid)
    }

    private func pressStayOnTop(_ wanted: Bool, pid: pid_t) {
        guard let window = deviceWindow(pid: pid), window.isFloating != wanted else { return }
        let axApp = AXUIElementCreateApplication(pid)
        guard let barRef = attr(axApp, kAXMenuBarAttribute) else { return }
        for top in children(barRef as! AXUIElement)
        where (attr(top, kAXTitleAttribute) as? String) == "Window" {
            for menu in children(top) {
                for item in children(menu)
                where (attr(item, kAXTitleAttribute) as? String) == "Stay On Top" {
                    AXUIElementPerformAction(item, kAXPressAction as CFString)
                    return
                }
            }
        }
    }

    private nonisolated func children(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success
        else { return [] }
        return (ref as? [AXUIElement]) ?? []
    }

    /// Union across CNVS's windows, not just the first visible one: SwiftUI
    /// keeps offscreen helper windows around that report no Space at all, and
    /// picking one of those made the comparison below silently no-op — which
    /// is how a stranded Simulator kept reading as "still launching".
    private func ownSpaces() -> Set<Int> {
        NSApp.windows
            .filter(\.isVisible)
            .reduce(into: Set<Int>()) { $0.formUnion(Spaces.spaces(of: CGWindowID($1.windowNumber))) }
    }

    /// Ends a cross-desktop standoff by moving CNVS instead of the Simulator.
    ///
    /// The device window can't be brought here: macOS won't move another
    /// app's window across Spaces, and relaunching doesn't help either —
    /// Simulator restores its window to the desktop it was last on, even when
    /// a different one is active (verified 2026-08-02, three attempts). What
    /// *is* allowed is a window declaring itself present on every Space, so
    /// CNVS does that and follows the Simulator over. Once they share a
    /// desktop, everything downstream — AX window lookup included — works.
    func followSimulator() {
        setJoinsAllSpaces(true)
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .activate(options: [.activateAllWindows])
        status = .locating
        startPolling()
    }

    /// Undone when the card closes so CNVS goes back to living on one desktop.
    func setJoinsAllSpaces(_ on: Bool) {
        for window in NSApp.windows where window.isVisible {
            if on { window.collectionBehavior.insert(.canJoinAllSpaces) }
            else { window.collectionBehavior.remove(.canJoinAllSpaces) }
        }
    }

    private nonisolated func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Pushes the real window's frame to `screenRect` — CG global
    /// coordinates, origin top-left of the primary display, y down.
    ///
    /// Size goes first and is treated as a *request*: Simulator quantises its
    /// window to zoom steps and rejects anything off-step outright (verified —
    /// kAXErrorFailure, and a squeezed-too-small window then stays squeezed).
    /// So we ask, read back what it actually took, and centre that in the
    /// card; otherwise a refused resize leaves the window pinned by its
    /// top-left corner and hanging off the card's edge.
    func dock(to screenRect: CGRect) {
        guard let win = axWindow else { return }
        var requested = screenRect.size
        if let v = AXValueCreate(.cgSize, &requested) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
        }
        var actual = screenRect.size
        if let v = attr(win, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue((v as! AXValue), .cgSize, &actual)
        }
        var pos = CGPoint(x: screenRect.midX - actual.width / 2,
                          y: screenRect.midY - actual.height / 2)
        guard let value = AXValueCreate(.cgPoint, &pos) else { return }
        let err = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, value)
        // Window gone (Simulator quit/relaunched) — without this, status
        // stays .docked with a dead reference and polling never resumes.
        if err == .invalidUIElement || err == .cannotComplete {
            axWindow = nil
            status = .locating
            startPolling()
        }
    }

    /// Brings the docked window in front of CNVS — needed because a plain
    /// AXRaise only reorders within Simulator's own windows; crossing above
    /// another app's window requires activating the app. Called on the
    /// initial dock and on card tap. Clicking elsewhere in CNVS will cover
    /// the window again — the card header stays visible, tap it to re-raise.
    func raise() {
        // Only when the window is actually here: activating Simulator while
        // its window sits on another desktop makes macOS switch Spaces, which
        // throws the user off CNVS entirely — the exact complaint that
        // surfaced this bug.
        guard status == .docked else { return }
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .activate(options: [])
        guard let win = axWindow else { return }
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    }

    /// Puts the real window away when the card closes, so it doesn't strand a
    /// floating window wherever it was last docked.
    ///
    /// Hiding the app rather than minimizing the window: hide is instant and
    /// keeps the window's frame, level and Accessibility handle intact, so
    /// reopening the card is a reposition and nothing else. Minimizing cost a
    /// genie animation each way and dropped the window out of the window list
    /// entirely, which the next lookup then had to rediscover.
    func stow() {
        setJoinsAllSpaces(false)
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
        else { return }
        // Stay On Top is deliberately left ticked. Unticking has to bring
        // Simulator forward first (the menu press is ignored otherwise), which
        // gated the hide behind half a second of visible shuffling — and a
        // hidden window floats above nothing anyway. `simulatorDidActivate`
        // drops the flag if the app comes back without CNVS docking it.
        stowed = true
        app.hide()
    }

    /// Hands Simulator back to normal window behaviour. Called on card close
    /// and on CNVS quitting — a floating phone left over an app that isn't
    /// running any more is just a window stuck over everything.
    func releaseStayOnTop() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
        else { return }
        setStayOnTop(false, pid: app.processIdentifier)
    }

    /// SwiftUI hands us a frame in its own window-local `.global` space
    /// (top-left origin, y down); AX wants CG global screen coordinates
    /// (top-left origin of the *primary* display, y down) — same handedness,
    /// only a screen-height flip sits between AppKit's window frame (bottom-
    /// left origin, y up) and the AX call.
    static func screenRect(forLocalFrame frame: CGRect, window: NSWindow) -> CGRect {
        let w = window.frame
        let topLeftAppKit = CGPoint(x: w.minX + frame.minX, y: w.maxY - frame.minY)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? topLeftAppKit.y
        let topLeftCG = CGPoint(x: topLeftAppKit.x, y: primaryHeight - topLeftAppKit.y)
        return CGRect(origin: topLeftCG, size: frame.size)
    }
}

/// The card's content when `kind == .simulator` — an otherwise-empty pane
/// whose only job is to keep the real Simulator.app window parked over it.
struct SimulatorDockView: View {
    @ObservedObject private var dock = SimulatorDockController.shared
    @State private var localFrame: CGRect = .zero
    /// The window this card actually lives in. `NSApp.windows.first(isVisible)`
    /// is not it — CNVS keeps other visible windows around (SwiftUI helpers,
    /// menu-bar-sized strips) and picking one of those offset the whole
    /// coordinate conversion, parking the device window off the left edge.
    @State private var hostWindow: NSWindow?
    /// One raise per card mount — repeated raises would steal focus back from
    /// CNVS every time the canvas moved.
    @State private var raised = false

    var body: some View {
        ZStack {
            switch dock.status {
            case .needsPermission:
                placeholder("needs accessibility access to dock the window", symbol: "lock.shield",
                            actionLabel: "open settings", action: dock.openAccessibilitySettings)
            case .notRunning:
                placeholder("simulator not running", symbol: "iphone.slash",
                            actionLabel: "open simulator", action: dock.launchIfNeeded)
            case .otherSpace:
                placeholder("simulator is on another desktop", symbol: "rectangle.on.rectangle",
                            actionLabel: "go to it", action: dock.followSimulator)
            case .locating, .noWindow:
                placeholder("waiting for device window…", symbol: "iphone",
                            actionLabel: nil, action: nil)
            case .docked:
                Color.clear // real window sits on top, parked to this rect
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowReader { hostWindow = $0; resync() })
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            localFrame = frame
            resync()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { _ in resync() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in resync() }
        // Geometry callbacks only fire on frame CHANGES — the moment the
        // window is first found (status → docked) needs its own kick, or the
        // window stays wherever Simulator left it.
        .onChange(of: dock.status) { _, newStatus in
            guard newStatus == .docked else { return }
            resync()
        }
        .task {
            // Reopening a card the controller never undocked leaves status
            // unchanged, so the onChange above won't fire and this is the only
            // thing that unhides the app. Nothing is awaited — whichever of
            // this and the geometry callback runs second does the docking, so
            // the phone lands with the card rather than a beat after it.
            dock.refresh()
            resync()
        }
    }

    private func resync() {
        guard localFrame != .zero, let window = hostWindow ?? NSApp.mainWindow else { return }
        dock.dock(to: SimulatorDockController.screenRect(forLocalFrame: localFrame, window: window))
        // Raise on the first sync that actually had a frame to work with, not
        // on mount: raising before the window is parked shows it at wherever
        // it was last left, which reads as a flash.
        guard !raised, dock.status == .docked else { return }
        raised = true
        dock.raise()
    }

    /// Hands back the NSWindow hosting this view, once AppKit has attached it.
    private struct WindowReader: NSViewRepresentable {
        let onWindow: (NSWindow?) -> Void

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            DispatchQueue.main.async { onWindow(view.window) }
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            DispatchQueue.main.async { onWindow(view.window) }
        }
    }

    private func placeholder(_ text: String, symbol: String, actionLabel: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Theme.headerText)
            Text(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.headerText)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.plain)
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

