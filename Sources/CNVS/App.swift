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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Notification.Name {
    static let cnvsNewTerminal = Notification.Name("cnvsNewTerminal")
    static let cnvsFocusCommandBar = Notification.Name("cnvsFocusCommandBar")
}
