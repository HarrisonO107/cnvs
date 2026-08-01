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

    private func clamp(to size: CGSize) {
        guard size.width > 300, size.height > 200 else { return }
        for i in store.cards.indices {
            var c = store.cards[i]
            c.width = min(c.width, size.width - 24)
            c.height = min(c.height, size.height - 24)
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
        GeometryReader { geo in
            ZStack {
                if let img = Self.customWallpaper {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(0.35))
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.14, blue: 0.24),
                            Color(red: 0.05, green: 0.08, blue: 0.16),
                            Color(red: 0.03, green: 0.04, blue: 0.09),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    RadialGradient(
                        colors: [Color(red: 0.35, green: 0.42, blue: 0.60).opacity(0.35), .clear],
                        center: .init(x: 0.75, y: 0.15),
                        startRadius: 0, endRadius: geo.size.width * 0.7
                    )
                    RadialGradient(
                        colors: [Theme.accent.opacity(0.08), .clear],
                        center: .init(x: 0.2, y: 0.9),
                        startRadius: 0, endRadius: geo.size.width * 0.5
                    )
                }
            }
        }
        .ignoresSafeArea()
    }

    // Drop a wallpaper at ~/Documents/CNVS/wallpaper.(jpg|png|heic) to replace the gradient.
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
