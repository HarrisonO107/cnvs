import AppKit
import ApplicationServices
import SwiftUI

/// Docks the real Simulator.app device window on top of a CNVS card by
/// pushing its frame (Accessibility API) to match the card's frame on
/// screen. Not true embedding — Apple exposes no cross-process view API —
/// but visually indistinguishable once parked, and fully interactive since
/// it's the real window.
@MainActor
final class SimulatorDockController: ObservableObject {
    enum Status: Equatable {
        case locating
        case notRunning
        case noWindow
        case docked
    }

    static let shared = SimulatorDockController()

    @Published private(set) var status: Status = .locating

    private var axWindow: AXUIElement?
    private var pollTimer: Timer?
    private let bundleID = "com.apple.iphonesimulator"

    /// Prompts once if CNVS isn't yet trusted for Accessibility — required to
    /// move another app's window. No-op once granted.
    func ensurePermission() {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
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
    /// found yet — the window mounts a beat after the process does.
    func refresh() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
        else {
            status = .notRunning
            axWindow = nil
            return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], let win = windows.first
        else {
            status = .noWindow
            axWindow = nil
            startPolling()
            return
        }
        axWindow = win
        status = .docked
        stopPolling()
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
    func dock(to screenRect: CGRect) {
        guard let win = axWindow else { return }
        var pos = screenRect.origin
        if let v = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
        }
        var size = screenRect.size
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
        }
    }

    /// Brings the docked window in front of other apps — called alongside
    /// CNVS's own card-raise, when the simulator card is tapped.
    func raise() {
        guard let win = axWindow else { return }
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    }

    /// Puts the real window away when the card closes, so it doesn't strand
    /// a floating window wherever it was last docked.
    func minimize() {
        guard let win = axWindow else { return }
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
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

    var body: some View {
        ZStack {
            switch dock.status {
            case .notRunning:
                placeholder("simulator not running", symbol: "iphone.slash",
                            actionLabel: "open simulator", action: dock.launchIfNeeded)
            case .locating, .noWindow:
                placeholder("waiting for device window…", symbol: "iphone",
                            actionLabel: nil, action: nil)
            case .docked:
                Color.clear // real window sits on top, parked to this rect
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            localFrame = frame
            resync()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { _ in resync() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in resync() }
        .task {
            dock.ensurePermission()
            dock.refresh()
        }
    }

    private func resync() {
        guard localFrame != .zero,
              let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.keyWindow
        else { return }
        dock.dock(to: SimulatorDockController.screenRect(forLocalFrame: localFrame, window: window))
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
