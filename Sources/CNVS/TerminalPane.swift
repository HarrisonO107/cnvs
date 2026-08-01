import SwiftUI
import SwiftTerm

/// Keeps live shell views alive across SwiftUI layout churn — dragging a card
/// must not kill its process.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var views: [UUID: LocalProcessTerminalView] = [:]
    private var sessions: [UUID: String] = [:]

    nonisolated static let tmuxBin: String = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/tmux"

    func view(for id: UUID, session: String?, bootCommand: String?) -> LocalProcessTerminalView {
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        if let session {
            // Every CNVS terminal lives in a creatoros-* tmux session so the
            // phone's terminal list sees it. Create it detached first (no-op if
            // the build listener already made it) so the status bar can be
            // switched off BEFORE the pane attaches — no green flash.
            sessions[id] = session
            Self.tmux(["new-session", "-d", "-s", session, "-c", home])
            Self.tmux(["set-option", "-t", session, "status", "off"])
            // Stamp the session as CNVS's. The phone's canvas asks the build listener
            // for `@cnvs` sessions alone (GET /tmux/windows?cnvs=1) — without this the
            // grid could not tell a pane from an ordinary Terminal.app tab. Set here
            // rather than only at creation so a session the listener made for the phone
            // is claimed the moment a CNVS pane adopts it.
            Self.tmux(["set-option", "-t", session, "@cnvs", "1"])
            tv.startProcess(
                executable: Self.tmuxBin,
                args: ["new-session", "-A", "-s", session],
                environment: envList,
                currentDirectory: home
            )
        } else {
            tv.startProcess(
                executable: "/bin/zsh",
                args: ["-l"],
                environment: envList,
                currentDirectory: home
            )
        }

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

    /// Voice routing: type into an existing pane as if Harrison had.
    func send(to id: UUID, text: String) {
        views[id]?.send(txt: text)
    }

    func session(for id: UUID) -> String? { sessions[id] }

    func remove(_ id: UUID) {
        views[id]?.removeFromSuperview()
        views[id] = nil
        if let session = sessions.removeValue(forKey: id) {
            // Closing the card closes the terminal everywhere, phone included.
            // `=` forces exact match so a short name can never prefix-hit another.
            Self.tmux(["kill-session", "-t", "=" + session])
        }
    }

    /// One-shot tmux query with captured stdout — voice routing reads each
    /// pane's cwd and recent output through this.
    nonisolated static func tmuxOutput(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxBin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One-shot tmux control command. These finish in milliseconds; the pane's
    /// own long-lived attach goes through startProcess, never through here.
    @discardableResult
    private static func tmux(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxBin)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

struct TerminalPane: NSViewRepresentable {
    let cardID: UUID
    let session: String?
    let bootCommand: String?

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        TerminalRegistry.shared.view(for: cardID, session: session, bootCommand: bootCommand)
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // SwiftTerm re-syncs its layer background from internal setup paths;
        // keep forcing it clear so the pane never goes opaque again.
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
