import SwiftUI

struct TodayUsage: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheWriteTokens = 0
    var cacheReadTokens = 0
    var messageCount = 0
    var estimatedCost = 0.0
    var byModel: [String: Int] = [:]
}

/// One rolling quota window (Claude Code's own 5-hour session limit, or the
/// 7-day weekly limit) — `usedPercent` and `resetsAt` are the real numbers
/// Anthropic returns, not an estimate.
struct RateLimitWindow: Equatable {
    var usedPercent: Double
    var resetsAt: Date
    var length: TimeInterval   // 5h or 7d, needed to work out pace/projection

    var elapsed: TimeInterval { max(0, min(length, length - resetsAt.timeIntervalSinceNow)) }
    var elapsedFraction: Double { length > 0 ? elapsed / length : 0 }

    /// used% minus "expected% if perfectly on pace for elapsed time".
    /// Positive = burning faster than the window allows (deficit).
    /// Negative = ahead of pace, banking headroom (reserve).
    var paceDelta: Double { usedPercent - elapsedFraction * 100 }

    /// Straight-line projection from window start through now — when you'd
    /// hit 100% if usage kept accruing at the average rate seen so far.
    var projectedEmpty: Date? {
        guard usedPercent > 0, elapsed > 0 else { return nil }
        let windowStart = resetsAt.addingTimeInterval(-length)
        return windowStart.addingTimeInterval(elapsed * (100 / usedPercent))
    }

    /// Will you actually run dry before this window resets, at current pace?
    var projectedToRunOut: Bool {
        guard let projectedEmpty else { return false }
        return projectedEmpty < resetsAt
    }
}

struct ClaudeLimitSnapshot: Equatable {
    // Real numbers, sourced from Claude Code's own statusline `rate_limits`
    // feed (same data the CLI's `/usage` and status bar show) — see
    // ~/.claude/statusline-command.sh, which drops each sample to
    // ~/.claude/cache/cnvs-rate-limits.json for this card to read.
    var session: RateLimitWindow?
    var week: RateLimitWindow?
    var sampledAt: Date?

    // ccusage-derived auxiliary: only used for the rough "sessions left"
    // estimate below, not for the headline percentages.
    var avgSessionTokens = 0
    var weekTokens = 0
    var estSessionsLeft: Int?

    var today = TodayUsage()
}

@MainActor
final class ClaudeUsageStore: ObservableObject {
    @Published var snapshot = ClaudeLimitSnapshot()
    @Published var loading = false
    @Published var unavailable = false

    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached { [weak self] in
            var mutableSnap = Self.readRateLimits()
            Self.attachSessionsLeftEstimate(&mutableSnap)
            mutableSnap.today = Self.scanToday()
            let snap = mutableSnap
            await MainActor.run { [weak self] in
                self?.snapshot = snap
                self?.unavailable = snap.session == nil && snap.week == nil
                self?.loading = false
            }
        }
    }

    // MARK: - Real quota: Claude Code's own rate_limits feed

    nonisolated private static func readRateLimits() -> ClaudeLimitSnapshot {
        var snap = ClaudeLimitSnapshot()
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/cache/cnvs-rate-limits.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return snap }

        if let sampledAt = obj["sampled_at"] as? Double {
            snap.sampledAt = Date(timeIntervalSince1970: sampledAt)
        }
        guard let rateLimits = obj["rate_limits"] as? [String: Any] else { return snap }

        if let fiveHour = rateLimits["five_hour"] as? [String: Any],
           let pct = fiveHour["used_percentage"] as? Double,
           let resets = fiveHour["resets_at"] as? Double {
            snap.session = RateLimitWindow(usedPercent: pct, resetsAt: Date(timeIntervalSince1970: resets), length: sessionWindowLength)
        }
        if let sevenDay = rateLimits["seven_day"] as? [String: Any],
           let pct = sevenDay["used_percentage"] as? Double,
           let resets = sevenDay["resets_at"] as? Double {
            snap.week = RateLimitWindow(usedPercent: pct, resetsAt: Date(timeIntervalSince1970: resets), length: weekWindowLength)
        }
        return snap
    }

    // MARK: - ccusage-derived: rough "sessions left" estimate only

    nonisolated private static func run(_ command: String) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    nonisolated private static func json(_ command: String) -> [String: Any]? {
        guard let data = run(command) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Converts the real weekly used% into a token-equivalent using ccusage's
    /// weekly token total, then divides remaining headroom by the average
    /// size of a past 5h block. Still an estimate — just anchored to the
    /// real weekly percentage instead of a personal-peak comparison.
    nonisolated private static func attachSessionsLeftEstimate(_ snap: inout ClaudeLimitSnapshot) {
        guard let week = snap.week, week.usedPercent > 0 else { return }

        var pastBlockTokens: [Int] = []
        if let all = json("ccusage claude blocks --json"),
           let allBlocks = all["blocks"] as? [[String: Any]] {
            pastBlockTokens = allBlocks
                .filter { ($0["isGap"] as? Bool) != true && ($0["isActive"] as? Bool) != true }
                .compactMap { $0["totalTokens"] as? Int }
        }
        guard !pastBlockTokens.isEmpty else { return }
        snap.avgSessionTokens = pastBlockTokens.reduce(0, +) / pastBlockTokens.count

        guard let weekly = json("ccusage claude weekly --json"),
              let weeks = weekly["weekly"] as? [[String: Any]],
              let currentTokens = weeks.last?["totalTokens"] as? Int, currentTokens > 0
        else { return }
        snap.weekTokens = currentTokens

        guard snap.avgSessionTokens > 0 else { return }
        let tokensPerPercent = Double(currentTokens) / week.usedPercent
        let remainingTokenEquivalent = (100 - week.usedPercent) * tokensPerPercent
        snap.estSessionsLeft = max(0, Int(remainingTokenEquivalent / Double(snap.avgSessionTokens)))
    }

    // MARK: - Raw local scan: today's tokens/cost/messages

    nonisolated private static func scanToday() -> TodayUsage {
        var usage = TodayUsage()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return usage }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()

        for projectDir in projectDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate, mtime >= startOfDay
                else { continue }
                guard let handle = FileHandle(forReadingAtPath: file.path) else { continue }
                defer { try? handle.close() }
                guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8)
                else { continue }

                for line in text.split(separator: "\n") where line.contains("\"usage\"") {
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let tsString = obj["timestamp"] as? String,
                          let ts = isoFrac.date(from: tsString) ?? iso.date(from: tsString),
                          ts >= startOfDay,
                          let message = obj["message"] as? [String: Any],
                          let msgUsage = message["usage"] as? [String: Any]
                    else { continue }

                    let model = message["model"] as? String ?? "unknown"
                    let inTok = msgUsage["input_tokens"] as? Int ?? 0
                    let outTok = msgUsage["output_tokens"] as? Int ?? 0
                    let cacheWrite = msgUsage["cache_creation_input_tokens"] as? Int ?? 0
                    let cacheRead = msgUsage["cache_read_input_tokens"] as? Int ?? 0

                    usage.inputTokens += inTok
                    usage.outputTokens += outTok
                    usage.cacheWriteTokens += cacheWrite
                    usage.cacheReadTokens += cacheRead
                    usage.messageCount += 1
                    usage.byModel[model, default: 0] += 1
                    usage.estimatedCost += cost(model: model, input: inTok, output: outTok,
                                                 cacheWrite: cacheWrite, cacheRead: cacheRead)
                }
            }
        }
        return usage
    }

    /// Rough $/MTok list-price estimate — close enough for a glance, not a bill.
    nonisolated private static func cost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        let m = model.lowercased()
        let rates: (input: Double, output: Double, cacheWrite: Double, cacheRead: Double)
        if m.contains("opus") {
            rates = (15, 75, 18.75, 1.50)
        } else if m.contains("haiku") {
            rates = (1, 5, 1.25, 0.10)
        } else {
            rates = (3, 15, 3.75, 0.30) // sonnet, fable, unknown — sonnet-tier default
        }
        return (Double(input) * rates.input + Double(output) * rates.output
                + Double(cacheWrite) * rates.cacheWrite + Double(cacheRead) * rates.cacheRead) / 1_000_000
    }
}

/// Short-and-sweet pill, same chrome as the command bar — not a resizable
/// card. Docks bottom-right of the window; tap for the full breakdown.
private let sessionWindowLength: TimeInterval = 5 * 3600
private let weekWindowLength: TimeInterval = 7 * 24 * 3600

struct ClaudeUsageBar: View {
    @StateObject private var store = ClaudeUsageStore()
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 11))
                .foregroundStyle(Theme.headerText)

            if store.unavailable {
                Text("no usage data yet")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.headerText)
            } else {
                gauge(label: "5h", percent: store.snapshot.session?.usedPercent)
                if let session = store.snapshot.session {
                    Text(formatDuration(session.resetsAt.timeIntervalSinceNow))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.headerText.opacity(0.7))
                }
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 14)
                gauge(label: "week", percent: store.snapshot.week?.usedPercent)
            }
            if store.loading { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .cardSurface()
        .contentShape(Rectangle())
        .onTapGesture { showDetail.toggle() }
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            ClaudeUsageDetailView(store: store)
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    @ViewBuilder
    private func gauge(label: String, percent: Double?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.mono(10, weight: .medium))
                .foregroundStyle(Theme.headerText)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: 34, height: 5)
                if let percent {
                    Capsule().fill(gaugeColor(percent)).frame(width: 34 * min(1, percent / 100), height: 5)
                }
            }
            Text(percent.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(Theme.mono(10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func gaugeColor(_ p: Double) -> Color {
        if p >= 90 { return Color(red: 0.95, green: 0.35, blue: 0.35) }
        if p >= 70 { return .orange }
        return Color(red: 0.45, green: 0.85, blue: 0.55)
    }
}

private func formatDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let h = total / 3600
    let m = (total % 3600) / 60
    return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
}

struct ClaudeUsageDetailView: View {
    @ObservedObject var store: ClaudeUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("claude usage")
                .font(Theme.mono(12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            section("session · resets in \(store.snapshot.session.map { formatDuration($0.resetsAt.timeIntervalSinceNow) } ?? "—")") {
                if let session = store.snapshot.session {
                    windowBody(session)
                } else {
                    row("used", "no data yet")
                }
            }

            section("weekly · resets in \(store.snapshot.week.map { formatDuration($0.resetsAt.timeIntervalSinceNow) } ?? "—")") {
                if let week = store.snapshot.week {
                    windowBody(week)
                    row("windows until reset", "\(max(0, Int(week.resetsAt.timeIntervalSinceNow / (5 * 3600))))")
                    if let left = store.snapshot.estSessionsLeft {
                        row("≈ session quotas left", "\(left)")
                    }
                } else {
                    row("used", "no data yet")
                }
            }

            section("today") {
                row("messages", "\(store.snapshot.today.messageCount)")
                row("in / out tokens", "\(formatTok(store.snapshot.today.inputTokens)) / \(formatTok(store.snapshot.today.outputTokens))")
                row("cache write / read", "\(formatTok(store.snapshot.today.cacheWriteTokens)) / \(formatTok(store.snapshot.today.cacheReadTokens))")
                row("est. cost", String(format: "~$%.2f", store.snapshot.today.estimatedCost))
                if !store.snapshot.today.byModel.isEmpty {
                    Text(store.snapshot.today.byModel.sorted { $0.value > $1.value }
                            .map { "\(shortModel($0.key)) ×\($0.value)" }
                            .joined(separator: "  ·  "))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.headerText)
                        .lineLimit(1)
                }
            }

            Text(store.unavailable
                 ? "No rate-limit sample yet — send a prompt in any Claude Code session to populate this."
                 : "5h/weekly are Anthropic's real numbers, read from Claude Code's own statusline feed — only updates while a session is actively running. Sessions-left and cost are rough local estimates.")
                .font(Theme.mono(8))
                .foregroundStyle(Theme.headerText.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }

    /// Shared body for a single quota window: big used%, bar with an on-pace
    /// tick, and the deficit/reserve pacing arrow — used for counts, not for
    /// left, so it climbs toward 100 rather than the plan draining down.
    @ViewBuilder
    private func windowBody(_ window: RateLimitWindow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(String(format: "%.0f", window.usedPercent))% used")
                .font(Theme.mono(14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            pacePill(window.paceDelta)
        }
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                Capsule().fill(gaugeColor(window.usedPercent))
                    .frame(width: geo.size.width * min(1, window.usedPercent / 100), height: 6)
                // on-pace tick: where you'd be if usage tracked elapsed time exactly
                Rectangle().fill(Color.white.opacity(0.55))
                    .frame(width: 1.5, height: 10)
                    .offset(x: geo.size.width * min(1, window.elapsedFraction) - 0.75, y: -2)
            }
        }
        .frame(height: 10)

        if window.projectedToRunOut, let empty = window.projectedEmpty {
            row("projected empty in", formatDuration(empty.timeIntervalSinceNow))
        } else {
            row("projected empty", "lasts until reset")
        }
    }

    @ViewBuilder
    private func pacePill(_ delta: Double) -> some View {
        let rounded = abs(delta).rounded()
        if rounded < 1 {
            Label("on target", systemImage: "arrow.right")
                .labelStyle(.titleAndIcon)
                .font(Theme.mono(9, weight: .medium))
                .foregroundStyle(Theme.headerText.opacity(0.8))
        } else if delta > 0 {
            Label("\(Int(rounded))% in deficit", systemImage: "arrow.up.right")
                .labelStyle(.titleAndIcon)
                .font(Theme.mono(9, weight: .medium))
                .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.35))
        } else {
            Label("\(Int(rounded))% in reserve", systemImage: "arrow.down.right")
                .labelStyle(.titleAndIcon)
                .font(Theme.mono(9, weight: .medium))
                .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55))
        }
    }

    private func gaugeColor(_ p: Double) -> Color {
        if p >= 90 { return Color(red: 0.95, green: 0.35, blue: 0.35) }
        if p >= 70 { return .orange }
        return Color(red: 0.45, green: 0.85, blue: 0.55)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Theme.mono(10, weight: .semibold))
                .foregroundStyle(Theme.accent.opacity(0.85))
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.mono(10)).foregroundStyle(Theme.headerText)
            Spacer()
            Text(value).font(Theme.mono(10, weight: .medium)).foregroundStyle(.white.opacity(0.88))
        }
    }

    private func formatTok(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func shortModel(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "")
    }
}
