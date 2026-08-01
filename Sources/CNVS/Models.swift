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

    func addTerminal(bootCommand: String? = nil) {
        let n = cards.filter { $0.kind == .terminal }.count + 1
        let top = (cards.map(\.z).max() ?? 0) + 1
        var card = Card(
            id: UUID(), kind: .terminal, title: "terminal \(n)",
            x: 60 + CGFloat(n % 5) * 32, y: 60 + CGFloat(n % 5) * 32,
            width: 680, height: 480, z: top
        )
        card.bootCommand = bootCommand
        cards.append(card)
    }

    func togglePanel(_ kind: CardKind) {
        if let existing = cards.first(where: { $0.kind == kind }) {
            close(existing.id)
        } else {
            let top = (cards.map(\.z).max() ?? 0) + 1
            let card = kind == .player
                ? Card(id: UUID(), kind: .player, title: "player", x: 830, y: 40, width: 460, height: 300, z: top)
                : Card(id: UUID(), kind: .notes, title: "notes", x: 830, y: 360, width: 460, height: 300, z: top)
            cards.append(card)
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
