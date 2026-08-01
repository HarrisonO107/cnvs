import SwiftUI

struct CNVSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("CNVS", id: "main") {
            RootView()
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 840)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Terminal") {
                    NotificationCenter.default.post(name: .cnvsNewTerminal, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])
                Button("Command Bar") {
                    NotificationCenter.default.post(name: .cnvsFocusCommandBar, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
                Button("Tidy Layout") {
                    NotificationCenter.default.post(name: .cnvsTidy, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .black
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            PhoneTerminalRequests.shared.accept(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `cnvs://terminal?session=creatoros-<digits>` — sent by the Mac build listener
/// when the phone asks for a terminal. Requests are queued rather than handled
/// inline because on a cold launch the URL arrives before RootView has mounted
/// its listeners; RootView drains the queue on appear and on each notification.
@MainActor
final class PhoneTerminalRequests {
    static let shared = PhoneTerminalRequests()
    private var pending: [String] = []

    func accept(_ url: URL) {
        guard url.scheme == "cnvs", url.host == "terminal",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let session = items.first(where: { $0.name == "session" })?.value,
              isValidSession(session)
        else { return }
        pending.append(session)
        NotificationCenter.default.post(name: .cnvsOpenPhoneTerminal, object: nil)
    }

    func drain() -> [String] {
        let out = pending
        pending = []
        return out
    }

    /// The session name goes into a shell command line, so only the listener's
    /// exact server-generated shape is allowed through.
    private func isValidSession(_ s: String) -> Bool {
        let prefix = "creatoros-"
        guard s.hasPrefix(prefix) else { return false }
        let digits = s.dropFirst(prefix.count)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

extension Notification.Name {
    static let cnvsNewTerminal = Notification.Name("cnvsNewTerminal")
    static let cnvsFocusCommandBar = Notification.Name("cnvsFocusCommandBar")
    static let cnvsTidy = Notification.Name("cnvsTidy")
    static let cnvsOpenPhoneTerminal = Notification.Name("cnvsOpenPhoneTerminal")
}
