import SwiftUI

/// The media card has two sources — Claude FM (YouTube livestream) and the
/// SoundCloud playlists — and only one of them is ever audible.
@MainActor
final class PlayerHub: ObservableObject {
    enum Source: String, CaseIterable {
        case radio, soundcloud

        var label: String { self == .radio ? "claude fm" : "soundcloud" }
        var cardTitle: String { self == .radio ? "claude radio" : "player" }
    }

    @Published var source: Source {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            // Only one source is ever audible, and coming back to the radio
            // means coming back to the live edge — not to a stale buffer.
            switch source {
            case .radio: music.pause(); radio.catchUp()
            case .soundcloud: radio.pause()
            }
        }
    }

    let radio = RadioModel()
    let music = PlayerModel()

    private static let sourceKey = "cnvs.player.source"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.sourceKey)
        source = saved.flatMap(Source.init(rawValue:)) ?? .radio
    }

    func select(_ next: Source) { source = next }

    func toggleSource() { source = source == .radio ? .soundcloud : .radio }
}

struct PlayerHostView: View {
    @ObservedObject var hub: PlayerHub

    var body: some View {
        switch hub.source {
        case .radio: RadioCardView(model: hub.radio)
        case .soundcloud: PlayerCardView(model: hub.music)
        }
    }
}

/// Source switch that lives in the card's header row, so the content area stays
/// pure video.
struct PlayerSourceChips: View {
    @ObservedObject var hub: PlayerHub

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PlayerHub.Source.allCases, id: \.self) { source in
                let active = hub.source == source
                Button(action: { hub.select(source) }) {
                    Text(source.label)
                        .font(Theme.mono(9, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.black.opacity(0.85) : Theme.headerText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(active ? Theme.accent : Color.white.opacity(0.07))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
