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

struct ClaudeLimitSnapshot: Equatable {
    var fiveHourTokens = 0
    var fiveHourPeakTokens = 0
    var fiveHourPercent: Double?     // active 5h block's tokens vs your busiest past 5h block
    var fiveHourResetMinutes: Int?

    var weekTokens = 0
    var weekPeakTokens = 0
    var weekPercent: Double?         // this week's tokens vs your busiest past week
    var avgSessionTokens = 0
    var estSessionsLeft: Int?        // rough "how many more typical sessions before matching your busiest week"

    var today = TodayUsage()
}

/// Anthropic doesn't expose actual plan-cap percentages anywhere (not via API,
/// not locally) — so instead of faking a number against an unknown limit,
/// this compares the live 5-hour/weekly window against Harrison's own busiest
/// past window. Genuinely his "getting close to how hard I usually go," not a
/// claim about the real account ceiling. Reads local session logs via
/// `ccusage` (already the tool his stay-within-limits skill recommends), plus
/// a direct scan of today's raw logs for the token/cost/message breakdown.
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
            var mutableSnap = Self.computeLimits()
            mutableSnap.today = Self.scanToday()
            let snap = mutableSnap
            await MainActor.run { [weak self] in
                self?.snapshot = snap
                self?.unavailable = snap.fiveHourPercent == nil && snap.weekPercent == nil
                self?.loading = false
            }
        }
    }

    // MARK: - ccusage-derived: 5h / weekly vs personal peak

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

    nonisolated private static func computeLimits() -> ClaudeLimitSnapshot {
        var snap = ClaudeLimitSnapshot()

        var pastBlockTokens: [Int] = []
        if let all = json("ccusage claude blocks --json"),
           let allBlocks = all["blocks"] as? [[String: Any]] {
            pastBlockTokens = allBlocks
                .filter { ($0["isGap"] as? Bool) != true && ($0["isActive"] as? Bool) != true }
                .compactMap { $0["totalTokens"] as? Int }
        }
        if !pastBlockTokens.isEmpty {
            snap.avgSessionTokens = pastBlockTokens.reduce(0, +) / pastBlockTokens.count
        }

        if let active = json("ccusage claude blocks --active --json"),
           let blocks = active["blocks"] as? [[String: Any]],
           let current = blocks.first(where: { ($0["isActive"] as? Bool) == true }),
           let currentTokens = current["totalTokens"] as? Int {
            snap.fiveHourTokens = currentTokens
            snap.fiveHourResetMinutes = (current["projection"] as? [String: Any])?["remainingMinutes"] as? Int
            if let peak = pastBlockTokens.max(), peak > 0 {
                snap.fiveHourPeakTokens = peak
                snap.fiveHourPercent = min(999, Double(currentTokens) / Double(peak) * 100)
            }
        }

        if let weekly = json("ccusage claude weekly --json"),
           let weeks = weekly["weekly"] as? [[String: Any]], weeks.count >= 2 {
            let currentTokens = weeks.last?["totalTokens"] as? Int ?? 0
            let priorPeak = weeks.dropLast().compactMap { $0["totalTokens"] as? Int }.max()
            snap.weekTokens = currentTokens
            if let priorPeak, priorPeak > 0 {
                snap.weekPeakTokens = priorPeak
                snap.weekPercent = min(999, Double(currentTokens) / Double(priorPeak) * 100)
                if snap.avgSessionTokens > 0 {
                    let headroom = max(0, priorPeak - currentTokens)
                    snap.estSessionsLeft = headroom / snap.avgSessionTokens
                }
            }
        }

        return snap
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
struct ClaudeUsageBar: View {
    @StateObject private var store = ClaudeUsageStore()
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 11))
                .foregroundStyle(Theme.headerText)

            if store.unavailable {
                Text("ccusage unavailable")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.headerText)
            } else {
                gauge(label: "5h", percent: store.snapshot.fiveHourPercent)
                if let mins = store.snapshot.fiveHourResetMinutes {
                    Text("\(mins)m")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.headerText.opacity(0.7))
                }
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 14)
                gauge(label: "week", percent: store.snapshot.weekPercent)
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

struct ClaudeUsageDetailView: View {
    @ObservedObject var store: ClaudeUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("claude usage")
                .font(Theme.mono(12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            section("this 5-hour window") {
                row("used", "\(formatTok(store.snapshot.fiveHourTokens)) tok")
                row("vs your busiest 5h ever", store.snapshot.fiveHourPeakTokens > 0
                    ? "\(formatTok(store.snapshot.fiveHourPeakTokens)) tok (\(pct(store.snapshot.fiveHourPercent)))"
                    : "no history yet")
                if let mins = store.snapshot.fiveHourResetMinutes {
                    row("resets in", "\(mins)m")
                }
            }

            section("this week") {
                row("used", "\(formatTok(store.snapshot.weekTokens)) tok")
                row("vs your busiest week ever", store.snapshot.weekPeakTokens > 0
                    ? "\(formatTok(store.snapshot.weekPeakTokens)) tok (\(pct(store.snapshot.weekPercent)))"
                    : "no history yet")
                if let left = store.snapshot.estSessionsLeft {
                    row("≈ sessions left before that", "\(left)")
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

            Text("5h/week are Harrison's own historical peaks, not Anthropic's real plan cap — that number isn't exposed anywhere. Cost is a list-price estimate, not a bill.")
                .font(Theme.mono(8))
                .foregroundStyle(Theme.headerText.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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

    private func pct(_ p: Double?) -> String { p.map { String(format: "%.0f%%", $0) } ?? "—" }

    private func formatTok(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func shortModel(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "")
    }
}
