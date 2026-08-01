import SwiftUI

struct ClaudeUsageSnapshot: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheWriteTokens = 0
    var cacheReadTokens = 0
    var messageCount = 0
    var estimatedCost = 0.0
    var byModel: [String: Int] = [:]
}

/// Reads today's token usage straight out of Claude Code's own session logs
/// (~/.claude/projects/**/*.jsonl) — no API key, no network, just what's
/// already on disk. Cost is a rough estimate against list pricing, not a bill.
@MainActor
final class ClaudeUsageStore: ObservableObject {
    @Published var today = ClaudeUsageSnapshot()
    @Published var loading = false

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
            let snap = Self.scan()
            await MainActor.run { [weak self] in
                self?.today = snap
                self?.loading = false
            }
        }
    }

    nonisolated private static func scan() -> ClaudeUsageSnapshot {
        var snap = ClaudeUsageSnapshot()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return snap }

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
                          let usage = message["usage"] as? [String: Any]
                    else { continue }

                    let model = message["model"] as? String ?? "unknown"
                    let inTok = usage["input_tokens"] as? Int ?? 0
                    let outTok = usage["output_tokens"] as? Int ?? 0
                    let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

                    snap.inputTokens += inTok
                    snap.outputTokens += outTok
                    snap.cacheWriteTokens += cacheWrite
                    snap.cacheReadTokens += cacheRead
                    snap.messageCount += 1
                    snap.byModel[model, default: 0] += 1
                    snap.estimatedCost += cost(model: model, input: inTok, output: outTok,
                                               cacheWrite: cacheWrite, cacheRead: cacheRead)
                }
            }
        }
        return snap
    }

    /// Rough $/MTok list-price estimate, blended across cache-ttl variants —
    /// close enough for a dashboard glance, not a substitute for the invoice.
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

struct ClaudeUsageView: View {
    @StateObject private var store = ClaudeUsageStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("claude usage — today")
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                if store.loading { ProgressView().controlSize(.mini) }
                Button(action: store.refresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.headerText)
            }

            Text(String(format: "~$%.2f", store.today.estimatedCost))
                .font(Theme.mono(24, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("estimate from local logs — not a bill")
                .font(Theme.mono(8))
                .foregroundStyle(Theme.headerText.opacity(0.7))

            VStack(alignment: .leading, spacing: 3) {
                statRow("messages", "\(store.today.messageCount)")
                statRow("in / out tokens", "\(formatTok(store.today.inputTokens)) / \(formatTok(store.today.outputTokens))")
                statRow("cache write / read", "\(formatTok(store.today.cacheWriteTokens)) / \(formatTok(store.today.cacheReadTokens))")
            }

            if !store.today.byModel.isEmpty {
                Text(store.today.byModel.sorted { $0.value > $1.value }
                        .map { "\(shortModel($0.key)) ×\($0.value)" }
                        .joined(separator: "  ·  "))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.headerText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.mono(10)).foregroundStyle(Theme.headerText)
            Spacer()
            Text(value).font(Theme.mono(10, weight: .medium)).foregroundStyle(.white.opacity(0.85))
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
