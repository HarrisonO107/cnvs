import SwiftUI

struct GitStatusSnapshot: Equatable {
    var repoPath: String
    var repoName: String
    var branch: String
    var ahead: Int
    var changedFiles: [String]
    var hasConflicts: Bool

    var totalChanged: Int { changedFiles.count }
}

enum GitAdvice {
    case none, clean, aheadOnly, readyToCommit, bigChange, conflict
}

/// Watches whichever hfjoandco project looks most recently touched and turns
/// `git status` into plain language — Harrison doesn't read git natively, so
/// this bar is the translation layer: is now a good time to commit or not.
@MainActor
final class GitHelperStore: ObservableObject {
    @Published var status: GitStatusSnapshot?
    @Published var advice: GitAdvice = .none
    @Published var committing = false
    @Published var message: String?

    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task.detached { [weak self] in
            let result = Self.probe()
            await MainActor.run { [weak self] in self?.apply(result) }
        }
    }

    private func apply(_ result: GitStatusSnapshot?) {
        status = result
        guard let result else { advice = .none; return }
        if result.hasConflicts { advice = .conflict }
        else if result.totalChanged == 0 { advice = result.ahead > 0 ? .aheadOnly : .clean }
        else if result.totalChanged > 15 { advice = .bigChange }
        else { advice = .readyToCommit }
    }

    func commit() {
        guard let status, !committing else { return }
        committing = true
        message = "writing commit message…"
        let dir = status.repoPath
        Task.detached { [weak self] in
            _ = Self.run(dir, ["add", "-A"])
            let diffStat = Self.run(dir, ["diff", "--cached", "--stat"])
            guard !diffStat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run { [weak self] in
                    self?.committing = false
                    self?.message = "nothing staged"
                }
                return
            }

            let prompt = "Write ONE git commit subject line, conventional-commits style, max 60 chars, " +
                "no body, no quotes, no explanation — ONLY the subject line — for this staged diffstat:\n\(diffStat)"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "claude -p \(prompt.shellQuoted) --model haiku 2>/dev/null | tail -1"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()

            // Never fall back to a placeholder subject — a bad/empty
            // generation means we bail without committing, not commit blind
            // under a meaningless message.
            var subject: String?
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !out.isEmpty, out.count <= 100, !out.contains("\n") { subject = out }
                }
            }

            guard let subject else {
                await MainActor.run { [weak self] in
                    self?.committing = false
                    self?.message = "couldn't write a message — try again"
                }
                return
            }

            let commitOut = Self.run(dir, ["commit", "-m", subject])
            let resultMsg = commitOut.contains("nothing to commit")
                ? "nothing staged"
                : "committed: \(subject)"

            await MainActor.run { [weak self] in
                self?.committing = false
                self?.message = resultMsg
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.message = nil }
            }
        }
    }

    nonisolated private static func run(_ dir: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "-C", dir] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return "" }
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Best-guess "project he's in right now" — whichever hfjoandco repo's
    /// HEAD moved most recently (commit, checkout, or branch switch).
    nonisolated private static func mostRecentRepo() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/hfjoandco")
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        let repos = dirs.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path)
        }
        func headModified(_ repo: URL) -> Date {
            let head = repo.appendingPathComponent(".git/HEAD")
            return (try? FileManager.default.attributesOfItem(atPath: head.path)[.modificationDate] as? Date)
                ?? .distantPast
        }
        return repos.max { headModified($0) < headModified($1) }
    }

    nonisolated private static func probe() -> GitStatusSnapshot? {
        guard let repo = mostRecentRepo() else { return nil }
        let dir = repo.path
        let name = repo.lastPathComponent
        let raw = run(dir, ["status", "--porcelain=v2", "--branch"])

        var branch = "?"
        var ahead = 0
        var files: [String] = []
        var conflicts = false

        for line in raw.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if let plus = parts.first, plus.hasPrefix("+") { ahead = Int(plus.dropFirst()) ?? 0 }
            } else if line.hasPrefix("u ") {
                conflicts = true
                if let path = line.split(separator: " ").last { files.append(String(path)) }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("? ") {
                if let path = line.split(separator: " ").last { files.append(String(path)) }
            }
        }

        return GitStatusSnapshot(
            repoPath: dir, repoName: name, branch: branch,
            ahead: ahead, changedFiles: files, hasConflicts: conflicts
        )
    }
}

/// Short-and-sweet pill, same chrome as the command bar — not a resizable
/// card. Docks bottom-left of the window; tap for the full breakdown.
struct GitHubStatusBar: View {
    @StateObject private var store = GitHelperStore()
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(Theme.headerText)

            if let status = store.status {
                Circle().fill(adviceColor).frame(width: 6, height: 6)
                Text(status.repoName)
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                Text(shortAdvice(status))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.headerText)
                    .lineLimit(1)

                if status.totalChanged > 0 && !status.hasConflicts {
                    Button(action: store.commit) {
                        Text(store.committing ? "…" : "commit")
                    }
                    .buttonStyle(.plain)
                    .font(Theme.mono(10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .disabled(store.committing)
                }
            } else {
                Text("no git project found")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.headerText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .cardSurface()
        .contentShape(Rectangle())
        .onTapGesture { showDetail.toggle() }
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            GitHubDetailView(store: store)
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    private var adviceColor: Color {
        switch store.advice {
        case .none, .clean: return Color(red: 0.55, green: 0.65, blue: 0.95)
        case .aheadOnly: return Theme.accent
        case .readyToCommit: return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .bigChange: return .orange
        case .conflict: return Color(red: 0.95, green: 0.35, blue: 0.35)
        }
    }

    private func shortAdvice(_ s: GitStatusSnapshot) -> String {
        switch store.advice {
        case .none: return ""
        case .clean: return "clean"
        case .aheadOnly: return "push \(s.ahead)"
        case .readyToCommit: return "\(s.totalChanged) file\(s.totalChanged == 1 ? "" : "s") — commit"
        case .bigChange: return "\(s.totalChanged) files — big"
        case .conflict: return "conflict!"
        }
    }
}

struct GitHubDetailView: View {
    @ObservedObject var store: GitHelperStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status = store.status {
                HStack(spacing: 6) {
                    Circle().fill(adviceColor).frame(width: 8, height: 8)
                    Text(status.repoName)
                        .font(Theme.mono(12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("· \(status.branch)")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.headerText)
                    Spacer()
                    Button(action: store.refresh) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.headerText)
                }

                Text(adviceText(status))
                    .font(Theme.mono(11))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)

                if !status.changedFiles.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(status.changedFiles, id: \.self) { f in
                                Text("· \(f)")
                                    .font(Theme.mono(9))
                                    .foregroundStyle(Theme.headerText)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }

                HStack {
                    if let msg = store.message {
                        Text(msg)
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.accent.opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer()
                    if status.totalChanged > 0 && !status.hasConflicts {
                        Button(action: store.commit) {
                            HStack(spacing: 4) {
                                if store.committing { ProgressView().controlSize(.mini) }
                                Text(store.committing ? "committing…" : "commit for me")
                            }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.mono(10, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .disabled(store.committing)
                    }
                }

                Text("watches whichever hfjoandco project you touched last (by .git/HEAD mtime).")
                    .font(Theme.mono(8))
                    .foregroundStyle(Theme.headerText.opacity(0.7))
            } else {
                Text("no git project found under hfjoandco")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.headerText)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var adviceColor: Color {
        switch store.advice {
        case .none, .clean: return Color(red: 0.55, green: 0.65, blue: 0.95)
        case .aheadOnly: return Theme.accent
        case .readyToCommit: return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .bigChange: return .orange
        case .conflict: return Color(red: 0.95, green: 0.35, blue: 0.35)
        }
    }

    private func adviceText(_ s: GitStatusSnapshot) -> String {
        switch store.advice {
        case .none: return ""
        case .clean: return "Nothing changed. Nothing to commit."
        case .aheadOnly: return "Committed but not pushed — \(s.ahead) commit\(s.ahead == 1 ? "" : "s") ahead. Push when ready: git push."
        case .readyToCommit: return "\(s.totalChanged) file\(s.totalChanged == 1 ? "" : "s") changed — looks like a clean checkpoint. Good time to commit."
        case .bigChange: return "\(s.totalChanged) files changed at once — fine to commit as a checkpoint, or keep going if it's one thought."
        case .conflict: return "Merge conflict — sort that out before touching anything else."
        }
    }
}
