import SwiftUI
import SwiftTerm

/// Keeps live shell views alive across SwiftUI layout churn — dragging a card
/// must not kill its process.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var views: [UUID: LocalProcessTerminalView] = [:]

    func view(for id: UUID, bootCommand: String?) -> LocalProcessTerminalView {
        if let existing = views[id] { return existing }

        let tv = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 600, height: 400))
        tv.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.nativeBackgroundColor = NSColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1)
        tv.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let envList = env.map { "\($0.key)=\($0.value)" }
        tv.startProcess(
            executable: "/bin/zsh",
            args: ["-l"],
            environment: envList,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )

        if let boot = bootCommand, !boot.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                tv.send(txt: boot + "\n")
            }
        }

        views[id] = tv
        return tv
    }

    func remove(_ id: UUID) {
        views[id]?.removeFromSuperview()
        views[id] = nil
    }
}

struct TerminalPane: NSViewRepresentable {
    let cardID: UUID
    let bootCommand: String?

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        TerminalRegistry.shared.view(for: cardID, bootCommand: bootCommand)
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
