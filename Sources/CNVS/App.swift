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
                Button("Notes") {
                    NotificationCenter.default.post(name: .cnvsNotesToggle, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Music") {
                    NotificationCenter.default.post(name: .cnvsMusicToggle, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Voice") {
                    NotificationCenter.default.post(name: .cnvsVoiceToggle, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [.option])
                Button("Wake Word") {
                    NotificationCenter.default.post(name: .cnvsWakeToggle, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [.option, .shift])
                Button("Simulator") {
                    NotificationCenter.default.post(name: .cnvsSimulatorToggle, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .black
        }
        // No App Nap: phone terminal requests must be handled while CNVS sits
        // in the background.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "phone terminal requests"
        )
        MainActor.assumeIsolated {
            PhoneTerminalRequests.shared.startWatching()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            PhoneTerminalRequests.shared.accept(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Card close undoes Stay On Top, but quitting with the card still open
    /// would leave the phone floating over every other app forever.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { SimulatorDockController.shared.releaseStayOnTop() }
    }
}

/// Terminal requests from the phone, two transports:
/// 1. Spool files in ~/.creatoros/cnvs-open — the build listener's path. A
///    kqueue watch fires even while CNVS is backgrounded; kAEGetURL does NOT
///    (URL events queue until the app activates, then flush as duplicates).
/// 2. cnvs://terminal?session=… — kept for manual/scripted opens.
/// Requests queue rather than run inline because on a cold launch they arrive
/// before RootView has mounted its listeners; RootView drains on appear and on
/// each notification, skipping sessions that already have a card.
@MainActor
final class PhoneTerminalRequests {
    static let shared = PhoneTerminalRequests()
    private var pending: [String] = []
    private var spoolSource: DispatchSourceFileSystemObject?
    private let spoolDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".creatoros/cnvs-open")

    func startWatching() {
        try? FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
        drainSpool()
        let fd = Darwin.open(spoolDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        src.setEventHandler { [weak self] in self?.drainSpool() }
        src.setCancelHandler { close(fd) }
        src.resume()
        spoolSource = src
    }

    private func drainSpool() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: spoolDir.path)
        else { return }
        for name in names.sorted() where isValidSession(name) {
            try? FileManager.default.removeItem(at: spoolDir.appendingPathComponent(name))
            enqueue(name)
        }
    }

    func accept(_ url: URL) {
        guard url.scheme == "cnvs", url.host == "terminal",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let session = items.first(where: { $0.name == "session" })?.value,
              isValidSession(session)
        else { return }
        enqueue(session)
    }

    private func enqueue(_ session: String) {
        guard !pending.contains(session) else { return }
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
    static let cnvsNotesToggle = Notification.Name("cnvsNotesToggle")
    static let cnvsMusicToggle = Notification.Name("cnvsMusicToggle")
    static let cnvsOpenPhoneTerminal = Notification.Name("cnvsOpenPhoneTerminal")
    static let cnvsVoiceToggle = Notification.Name("cnvsVoiceToggle")
    static let cnvsWakeToggle = Notification.Name("cnvsWakeToggle")
    static let cnvsSimulatorToggle = Notification.Name("cnvsSimulatorToggle")
    /// Device window found or resized — the layout needs to re-fit its card.
    static let cnvsSimulatorSized = Notification.Name("cnvsSimulatorSized")
}
