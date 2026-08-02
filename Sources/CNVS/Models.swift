import SwiftUI

enum CardKind: String, Codable {
    case terminal, player, notes, simulator
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
    var isFullscreen: Bool = false // not persisted
    var preFullscreenFrame: CGRect? // not persisted

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
    /// Card chrome above the content — matched to the header's fixed height so
    /// the simulator card's content area comes out exactly device-sized.
    static let simulatorHeader: CGFloat = 30

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
            // The SoundCloud player became the Claude FM radio; relabel layouts
            // saved before that.
            for i in saved.indices where saved[i].kind == .player && saved[i].title == "player" {
                saved[i].title = Self.radioTitle
            }
            cards = saved
        } else {
            cards = Self.defaultLayout()
        }
    }

    static let radioTitle = "claude radio"

    static func defaultLayout() -> [Card] {
        [
            Card(id: UUID(), kind: .terminal, title: "terminal", x: 40, y: 40, width: 760, height: 620, z: 1, session: newSessionName()),
            Card(id: UUID(), kind: .player, title: radioTitle, x: 830, y: 40, width: 460, height: 430, z: 2),
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

    /// Maximizes a card to fill the canvas, or restores it to its pre-maximize
    /// frame. Not real macOS fullscreen — the dock can't host anything once
    /// CNVS itself goes fullscreen — just "this card fills the window."
    func toggleFullscreen(_ id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        // The docked Simulator device window is a real OS window, kept Stay On
        // Top of everything by design — SwiftUI z-index inside CNVS can never
        // cover it, so a card going fullscreen has to actually hide it for
        // real, not just draw over it.
        let touchesSimulator = cards[idx].kind != .simulator

        if cards[idx].isFullscreen {
            if let f = cards[idx].preFullscreenFrame {
                cards[idx].x = f.origin.x
                cards[idx].y = f.origin.y
                cards[idx].width = f.width
                cards[idx].height = f.height
            }
            cards[idx].preFullscreenFrame = nil
            cards[idx].isFullscreen = false
            if touchesSimulator {
                SimulatorDockController.shared.suppressed = false
                if cards.contains(where: { $0.kind == .simulator }) {
                    SimulatorDockController.shared.refresh()
                }
            }
        } else {
            cards[idx].preFullscreenFrame = CGRect(
                x: cards[idx].x, y: cards[idx].y,
                width: cards[idx].width, height: cards[idx].height
            )
            cards[idx].x = Self.margin
            cards[idx].y = Self.margin
            cards[idx].width = canvasSize.width - 2 * Self.margin
            cards[idx].height = canvasSize.height - 2 * Self.margin - Self.commandBarClearance
            cards[idx].isFullscreen = true
            raise(id)
            if touchesSimulator {
                SimulatorDockController.shared.suppressed = true
                if cards.contains(where: { $0.kind == .simulator }) {
                    SimulatorDockController.shared.stow()
                }
            }
        }
    }

    func close(_ id: UUID) {
        if let card = cards.first(where: { $0.id == id }) {
            switch card.kind {
            case .terminal: TerminalRegistry.shared.remove(card.id)
            case .simulator: SimulatorDockController.shared.stow()
            case .player, .notes: break
            }
            // Closing a card mid-fullscreen must not leave the real Simulator
            // window suppressed forever with nothing left to un-suppress it.
            if card.isFullscreen, card.kind != .simulator {
                SimulatorDockController.shared.suppressed = false
                if cards.contains(where: { $0.kind == .simulator && $0.id != id }) {
                    SimulatorDockController.shared.refresh()
                }
            }
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
            let (title, size) = defaultsForToggle(kind)
            cards.append(Card(
                id: UUID(), kind: kind, title: title,
                x: Self.margin, y: Self.margin, width: size.width, height: size.height, z: top
            ))
        }
        tidy()
    }

    private func defaultsForToggle(_ kind: CardKind) -> (title: String, size: CGSize) {
        switch kind {
        case .player: return (Self.radioTitle, CGSize(width: 460, height: 300))
        case .notes: return ("notes", CGSize(width: 460, height: 300))
        case .simulator: return ("simulator", CGSize(width: 420, height: 720)) // phone-shaped, not squashed to the panel split
        case .terminal: return ("terminal", CGSize(width: 680, height: 480))
        }
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

        // The simulator card gets its own column sized to the real device
        // window: Simulator refuses every programmatic resize, so a card cut
        // to the panel column's share would just have a phone overhanging it.
        if let sim = cards.firstIndex(where: { $0.kind == .simulator }), !cards[sim].isFullscreen,
           let device = SimulatorDockController.shared.deviceSize {
            let width = min(device.width, free.width)
            let height = min(device.height + Self.simulatorHeader, free.height)
            cards[sim].x = free.maxX - width
            cards[sim].y = free.minY
            cards[sim].width = width
            cards[sim].height = height
            free.size.width -= width + g
        }

        let side = cards.indices
            .filter { cards[$0].kind != .terminal && cards[$0].kind != .simulator && !cards[$0].isFullscreen }
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
            .filter { cards[$0].kind == .terminal && !cards[$0].isFullscreen }
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
