import SwiftUI

enum CardKind: String, Codable {
    case terminal, player, notes
}

struct Card: Identifiable, Codable {
    let id: UUID
    var kind: CardKind
    var title: String
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var z: Double
    /// Backing tmux session for terminal cards (creatoros-<digits>), persisted
    /// so a relaunch reattaches the same shells and the phone list stays true.
    var session: String?

    var bootCommand: String? // not persisted

    enum CodingKeys: String, CodingKey {
        case id, kind, title, x, y, width, height, z, session
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var cards: [Card] = [] {
        didSet { scheduleSave() }
    }

    static let margin: CGFloat = 12
    static let gutter: CGFloat = 12
    /// Tiles stop short of the floating command bar at the bottom.
    static let commandBarClearance: CGFloat = 56

    /// Kept current by RootView; placement needs it to know where cards fit.
    var canvasSize = CGSize(width: 1380, height: 800)

    private var saveWork: DispatchWorkItem?
    private let saveKey = "cnvs.workspace.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           var saved = try? JSONDecoder().decode([Card].self, from: data),
           !saved.isEmpty {
            // Terminals saved before sessions existed get one now, so every
            // pane is tmux-backed and phone-visible after this launch.
            for i in saved.indices where saved[i].kind == .terminal && saved[i].session == nil {
                saved[i].session = Self.newSessionName()
            }
            // The queued-URL-flush bug could persist several cards for one
            // session; keep the first of each.
            var seen = Set<String>()
            saved.removeAll { card in
                guard let s = card.session else { return false }
                return !seen.insert(s).inserted
            }
            cards = saved
        } else {
            cards = Self.defaultLayout()
        }
    }

    static func defaultLayout() -> [Card] {
        [
            Card(id: UUID(), kind: .terminal, title: "terminal", x: 40, y: 40, width: 760, height: 620, z: 1, session: newSessionName()),
            Card(id: UUID(), kind: .player, title: "player", x: 830, y: 40, width: 460, height: 430, z: 2),
            Card(id: UUID(), kind: .notes, title: "notes", x: 830, y: 490, width: 460, height: 270, z: 3),
        ]
    }

    /// Same shape the build listener generates — the phone's list and kill
    /// endpoint both require creatoros-<digits> exactly.
    static func newSessionName() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        return "creatoros-\(ms)\(Int.random(in: 100...999))"
    }

    func raise(_ id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        let top = (cards.map(\.z).max() ?? 0) + 1
        cards[idx].z = top
    }

    func close(_ id: UUID) {
        if let card = cards.first(where: { $0.id == id }), card.kind == .terminal {
            TerminalRegistry.shared.remove(card.id)
        }
        cards.removeAll { $0.id == id }
    }

    func addTerminal(bootCommand: String? = nil, title: String? = nil, session: String? = nil) {
        let n = cards.filter { $0.kind == .terminal }.count + 1
        let top = (cards.map(\.z).max() ?? 0) + 1
        var card = Card(
            id: UUID(), kind: .terminal, title: title ?? "terminal \(n)",
            x: Self.margin, y: Self.margin, width: 680, height: 480, z: top,
            session: session ?? Self.newSessionName()
        )
        card.bootCommand = bootCommand
        cards.append(card)
        // Start the shell NOW, not at first render — with the window occluded
        // (phone-triggered opens), SwiftUI defers makeNSView indefinitely and
        // the tmux session would never attach.
        _ = TerminalRegistry.shared.view(for: card.id, session: card.session, bootCommand: card.bootCommand)
        tidy()
    }

    func togglePanel(_ kind: CardKind) {
        if let existing = cards.first(where: { $0.kind == kind }) {
            close(existing.id)
        } else {
            let top = (cards.map(\.z).max() ?? 0) + 1
            cards.append(Card(
                id: UUID(), kind: kind, title: kind == .player ? "player" : "notes",
                x: Self.margin, y: Self.margin, width: 460, height: 300, z: top
            ))
        }
        tidy()
    }

    // MARK: - Layout

    /// Deliberate layout, not nearest-slot snapping: player and notes dock as a
    /// column on the far right; every terminal gets the SAME size, tiled
    /// side-by-side (wrapping to rows only when columns would get too narrow)
    /// in the remaining space. Runs on every spawn/toggle and on ⌘G — manual
    /// drags stay wherever they were dropped until then.
    func tidy() {
        let g = Self.gutter
        var free = CGRect(
            x: Self.margin, y: Self.margin,
            width: canvasSize.width - 2 * Self.margin,
            height: canvasSize.height - 2 * Self.margin - Self.commandBarClearance
        )

        let side = cards.indices
            .filter { cards[$0].kind != .terminal }
            .sorted { cards[$0].kind == .player && cards[$1].kind != .player }
        if !side.isEmpty {
            let panelW = min(460, free.width * 0.38)
            let count = CGFloat(side.count)
            let panelH = (free.height - g * (count - 1)) / count
            var y = free.minY
            for i in side {
                cards[i].x = free.maxX - panelW
                cards[i].y = y
                cards[i].width = panelW
                cards[i].height = panelH
                y += panelH + g
            }
            free.size.width -= panelW + g
        }

        let terms = cards.indices
            .filter { cards[$0].kind == .terminal }
            .sorted { (cards[$0].y, cards[$0].x) < (cards[$1].y, cards[$1].x) }
        guard !terms.isEmpty else { return }

        let n = terms.count
        var cols = n
        while cols > 1 && (free.width - g * CGFloat(cols - 1)) / CGFloat(cols) < 380 {
            cols -= 1
        }
        var rows = Int(ceil(Double(n) / Double(cols)))
        while rows > 1 && cols < n
            && (free.height - g * CGFloat(rows - 1)) / CGFloat(rows) < 240 {
            cols += 1
            rows = Int(ceil(Double(n) / Double(cols)))
        }

        // Balanced rows, each spanning the full region width — an uneven count
        // stretches the shorter rows (7 → 2+2+3, widest on top) so no patch of
        // canvas sits empty.
        let base = n / rows
        let extra = n % rows
        let rowCounts = (0..<rows).map { $0 >= rows - extra ? base + 1 : base }
        let cellH = (free.height - g * CGFloat(rows - 1)) / CGFloat(rows)
        var k = 0
        for (r, count) in rowCounts.enumerated() {
            let cellW = (free.width - g * CGFloat(count - 1)) / CGFloat(count)
            for c in 0..<count {
                let i = terms[k]
                k += 1
                cards[i].x = free.minX + CGFloat(c) * (cellW + g)
                cards[i].y = free.minY + CGFloat(r) * (cellH + g)
                cards[i].width = cellW
                cards[i].height = cellH
            }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(self.cards) {
                UserDefaults.standard.set(data, forKey: self.saveKey)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
