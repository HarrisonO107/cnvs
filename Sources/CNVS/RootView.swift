import SwiftUI

struct RootView: View {
    @StateObject private var store = WorkspaceStore()
    @StateObject private var player = PlayerModel()
    @StateObject private var notes = NotesStore()
    @State private var commandText = ""
    @FocusState private var commandFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Wallpaper()

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach($store.cards) { $card in
                        CardView(card: $card, store: store, player: player, notes: notes)
                            .zIndex(card.z)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onAppear { clamp(to: geo.size) }
                .onChange(of: geo.size) { clamp(to: geo.size) }
            }
            .padding(.top, 28) // clear the traffic lights

            commandBar
                .padding(.bottom, 14)
        }
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .cnvsNewTerminal)) { _ in
            store.addTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cnvsFocusCommandBar)) { _ in
            commandFocused = true
        }
    }

    @State private var lastSize: CGSize?

    /// Scale the whole layout with the window (fullscreen shouldn't strand
    /// cards in a corner), then keep everything inside the visible frame.
    private func clamp(to size: CGSize) {
        guard size.width > 300, size.height > 200 else { return }
        defer { lastSize = size }

        var scaleW: CGFloat = 1, scaleH: CGFloat = 1
        if let old = lastSize, old.width > 300, old.height > 200,
           abs(old.width - size.width) + abs(old.height - size.height) > 1 {
            scaleW = size.width / old.width
            scaleH = size.height / old.height
        }

        for i in store.cards.indices {
            var c = store.cards[i]
            c.x *= scaleW
            c.width *= scaleW
            c.y *= scaleH
            c.height *= scaleH
            c.width = max(280, min(c.width, size.width - 24))
            c.height = max(180, min(c.height, size.height - 24))
            c.x = max(12, min(c.x, size.width - c.width - 12))
            c.y = max(0, min(c.y, size.height - c.height - 12))
            store.cards[i] = c
        }
    }

    private var commandBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.accent.opacity(commandFocused ? 0.9 : 0.35))
                .frame(width: 6, height: 6)
            TextField("ask claude — opens a new terminal", text: $commandText)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(.white.opacity(0.9))
                .focused($commandFocused)
                .onSubmit {
                    let prompt = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !prompt.isEmpty else { return }
                    store.addTerminal(bootCommand: "claude " + prompt.shellQuoted)
                    commandText = ""
                    commandFocused = false
                }
            Text("⌘K")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.headerText)

            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 16)

            barButton("terminal.fill", help: "new terminal (⌘T)") { store.addTerminal() }
            barButton("music.note", help: "toggle player") { store.togglePanel(.player) }
            barButton("note.text", help: "toggle notes") { store.togglePanel(.notes) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 560)
        .cardSurface()
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.headerText)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct CardView: View {
    @Binding var card: Card
    let store: WorkspaceStore
    let player: PlayerModel
    let notes: NotesStore

    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGSize?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: card.width, height: card.height)
        .cardSurface()
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .offset(x: card.x, y: card.y)
        .simultaneousGesture(
            TapGesture().onEnded { store.raise(card.id) }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(kindColor).frame(width: 7, height: 7)
            Text(card.title)
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(Theme.headerText)
            Spacer()
            Button(action: { store.close(card.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.headerText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.white.opacity(0.03))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { v in
                    if dragStart == nil {
                        dragStart = CGPoint(x: card.x, y: card.y)
                        store.raise(card.id)
                    }
                    card.x = max(-card.width + 80, dragStart!.x + v.translation.width)
                    card.y = max(0, dragStart!.y + v.translation.height)
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    private var resizeGrip: some View {
        Image(systemName: "line.diagonal")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.headerText.opacity(0.6))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { v in
                        if resizeStart == nil {
                            resizeStart = CGSize(width: card.width, height: card.height)
                        }
                        card.width = max(280, resizeStart!.width + v.translation.width)
                        card.height = max(180, resizeStart!.height + v.translation.height)
                    }
                    .onEnded { _ in resizeStart = nil }
            )
    }

    @ViewBuilder
    private var content: some View {
        switch card.kind {
        case .terminal:
            TerminalPane(cardID: card.id, bootCommand: card.bootCommand)
                .background(Theme.terminalBackground)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: Theme.cardRadius,
                        bottomTrailingRadius: Theme.cardRadius
                    )
                )
        case .player:
            PlayerCardView(model: player)
        case .notes:
            NotesCardView(store: notes)
        }
    }

    private var kindColor: Color {
        switch card.kind {
        case .terminal: return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .player: return Theme.accent
        case .notes: return Color(red: 0.55, green: 0.65, blue: 0.95)
        }
    }
}

struct Wallpaper: View {
    var body: some View {
        Group {
            if let img = Self.customWallpaper {
                GeometryReader { geo in
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(0.35))
                }
            } else {
                NightSky()
            }
        }
        .ignoresSafeArea()
    }

    // Drop a wallpaper at ~/Documents/CNVS/wallpaper.(jpg|png|heic) to replace the sky.
    static let customWallpaper: NSImage? = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/CNVS")
        for ext in ["jpg", "jpeg", "png", "heic"] {
            let url = base.appendingPathComponent("wallpaper.\(ext)")
            if let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }()
}

/// Procedural animated night sky: slow-drifting mesh gradient, twinkling
/// stars, warm horizon glow, vignette.
struct NightSky: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    mesh(t)
                    StarField(t: t)
                        .blendMode(.screen)
                    RadialGradient(
                        colors: [Color(red: 0.45, green: 0.52, blue: 0.75).opacity(0.20), .clear],
                        center: .init(x: 0.72, y: 0.10),
                        startRadius: 0, endRadius: geo.size.width * 0.55
                    )
                    .blendMode(.screen)
                    RadialGradient(
                        colors: [Theme.accent.opacity(0.13), .clear],
                        center: .init(x: 0.30, y: 1.02),
                        startRadius: 0, endRadius: geo.size.width * 0.55
                    )
                    .blendMode(.screen)
                    RadialGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        center: .center,
                        startRadius: min(geo.size.width, geo.size.height) * 0.35,
                        endRadius: max(geo.size.width, geo.size.height) * 0.80
                    )
                }
            }
        }
    }

    private func mesh(_ t: Double) -> some View {
        func drift(_ phase: Double, _ speed: Double, _ amp: Float) -> Float {
            Float(sin(t * speed + phase)) * amp
        }
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5 + drift(0.0, 0.050, 0.08), 0], [1, 0],
                [0, 0.5 + drift(1.3, 0.040, 0.06)],
                [0.5 + drift(2.1, 0.033, 0.14), 0.5 + drift(0.7, 0.047, 0.10)],
                [1, 0.5 + drift(3.0, 0.044, 0.06)],
                [0, 1], [0.5 + drift(4.2, 0.037, 0.08), 1], [1, 1],
            ],
            colors: [
                Color(red: 0.030, green: 0.045, blue: 0.100),
                Color(red: 0.060, green: 0.090, blue: 0.190),
                Color(red: 0.035, green: 0.050, blue: 0.110),
                Color(red: 0.050, green: 0.070, blue: 0.150),
                Color(red: 0.105, green: 0.135, blue: 0.260),
                Color(red: 0.055, green: 0.072, blue: 0.140),
                Color(red: 0.016, green: 0.022, blue: 0.045),
                Color(red: 0.085, green: 0.068, blue: 0.085),
                Color(red: 0.016, green: 0.022, blue: 0.045),
            ]
        )
    }
}

struct StarField: View {
    let t: Double

    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x51F3_9A2B_77C4_D01E
            func rnd() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double((seed >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
            }
            for _ in 0..<170 {
                let x = rnd() * size.width
                let y = pow(rnd(), 1.7) * size.height * 0.80 // denser up top
                let r = 0.4 + rnd() * 1.2
                let phase = rnd() * .pi * 2
                let speed = 0.25 + rnd() * 1.1
                let base = 0.10 + rnd() * 0.55
                let twinkle = 0.55 + 0.45 * sin(t * speed + phase)
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(base * twinkle)))
            }
        }
    }
}
