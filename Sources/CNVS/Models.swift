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

    var bootCommand: String? // not persisted

    enum CodingKeys: String, CodingKey {
        case id, kind, title, x, y, width, height, z
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var cards: [Card] = [] {
        didSet { scheduleSave() }
    }

    static let gridStep: CGFloat = 40
    static let margin: CGFloat = 12
    static let gutter: CGFloat = 12

    /// Kept current by RootView; placement needs it to know where cards fit.
    var canvasSize = CGSize(width: 1380, height: 800)

    private var saveWork: DispatchWorkItem?
    private let saveKey = "cnvs.workspace.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let saved = try? JSONDecoder().decode([Card].self, from: data),
           !saved.isEmpty {
            cards = saved
        } else {
            cards = Self.defaultLayout()
        }
    }

    static func defaultLayout() -> [Card] {
        [
            Card(id: UUID(), kind: .terminal, title: "terminal", x: 40, y: 40, width: 760, height: 620, z: 1),
            Card(id: UUID(), kind: .player, title: "player", x: 830, y: 40, width: 460, height: 430, z: 2),
            Card(id: UUID(), kind: .notes, title: "notes", x: 830, y: 490, width: 460, height: 270, z: 3),
        ]
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

    func addTerminal(bootCommand: String? = nil, title: String? = nil) {
        let n = cards.filter { $0.kind == .terminal }.count + 1
        let top = (cards.map(\.z).max() ?? 0) + 1
        let size = CGSize(width: 680, height: 480)
        let origin = spawnOrigin(for: size)
        var card = Card(
            id: UUID(), kind: .terminal, title: title ?? "terminal \(n)",
            x: origin.x, y: origin.y,
            width: size.width, height: size.height, z: top
        )
        card.bootCommand = bootCommand
        cards.append(card)
    }

    func togglePanel(_ kind: CardKind) {
        if let existing = cards.first(where: { $0.kind == kind }) {
            close(existing.id)
        } else {
            let top = (cards.map(\.z).max() ?? 0) + 1
            let size = CGSize(width: 460, height: 300)
            let origin = spawnOrigin(for: size)
            let card = Card(
                id: UUID(), kind: kind, title: kind == .player ? "player" : "notes",
                x: origin.x, y: origin.y, width: size.width, height: size.height, z: top
            )
            cards.append(card)
        }
    }

    // MARK: - Grid layout

    /// New cards land on the first free grid slot (rows, left→right) so nothing
    /// spawns overlapping. Manual drags are never snapped — only spawn and
    /// tidy() touch the grid.
    private func spawnOrigin(for size: CGSize) -> CGPoint {
        let taken = cards.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        if let slot = freeSlots(for: size, avoiding: taken).first {
            return slot
        }
        // Canvas full — cascade so the card is at least visible and grabbable.
        let n = cards.count
        return CGPoint(
            x: Self.margin + CGFloat(n % 8) * Self.gridStep,
            y: Self.margin + CGFloat(n % 8) * Self.gridStep
        )
    }

    /// Snap every card to its nearest free grid slot. Sweeps top-left first so
    /// the result reads as rows; collisions push a card to the next-nearest slot.
    func tidy() {
        let step = Self.gridStep
        var placed: [CGRect] = []
        let order = cards.indices.sorted {
            (cards[$0].y, cards[$0].x) < (cards[$1].y, cards[$1].x)
        }
        for i in order {
            var c = cards[i]
            c.width = min(max(280, round(c.width / step) * step), canvasSize.width - 2 * Self.margin)
            c.height = min(max(180, round(c.height / step) * step), canvasSize.height - 2 * Self.margin)
            let size = CGSize(width: c.width, height: c.height)
            let target = CGPoint(
                x: Self.margin + round((c.x - Self.margin) / step) * step,
                y: Self.margin + round((c.y - Self.margin) / step) * step
            )
            let slots = freeSlots(for: size, avoiding: placed)
            let origin = slots.min(by: {
                hypot($0.x - target.x, $0.y - target.y) < hypot($1.x - target.x, $1.y - target.y)
            }) ?? target
            c.x = origin.x
            c.y = origin.y
            placed.append(CGRect(x: c.x, y: c.y, width: c.width, height: c.height))
            cards[i] = c
        }
    }

    /// Every grid origin where a card of `size` fits inside the canvas without
    /// touching `avoiding` (plus a gutter), in row-major order.
    private func freeSlots(for size: CGSize, avoiding: [CGRect]) -> [CGPoint] {
        let step = Self.gridStep
        var slots: [CGPoint] = []
        var y = Self.margin
        while y + size.height <= canvasSize.height - Self.margin {
            var x = Self.margin
            while x + size.width <= canvasSize.width - Self.margin {
                let candidate = CGRect(x: x, y: y, width: size.width, height: size.height)
                    .insetBy(dx: -Self.gutter, dy: -Self.gutter)
                if !avoiding.contains(where: { $0.intersects(candidate) }) {
                    slots.append(CGPoint(x: x, y: y))
                }
                x += step
            }
            y += step
        }
        return slots
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
