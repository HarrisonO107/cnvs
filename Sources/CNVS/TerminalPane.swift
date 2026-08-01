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
        // Alpha 0 keeps every SwiftTerm background fill a no-op (true glass),
        // while the RGB components give shells querying the terminal colour
        // (OSC 11 — Claude Code theme detection) a sane dark navy instead of
        // whatever NSColor.clear converts to.
        tv.nativeBackgroundColor = NSColor(srgbRed: 0.03, green: 0.045, blue: 0.09, alpha: 0.0)
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

        // SwiftTerm only pushes nativeBackgroundColor to its layer once, in
        // setupOptions() — assigning the color later never reaches the layer,
        // so stamp it clear ourselves or the pane stays opaque.
        tv.layer?.backgroundColor = NSColor.clear.cgColor

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

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // SwiftTerm re-syncs its layer background from internal setup paths;
        // keep forcing it clear so the pane never goes opaque again.
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
