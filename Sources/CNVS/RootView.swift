import SwiftUI

struct RootView: View {
    @StateObject private var store = WorkspaceStore()
    @StateObject private var hub = PlayerHub()
    @StateObject private var notes = NotesStore()
    @StateObject private var voice = VoiceController()
    @State private var commandText = ""
    @FocusState private var commandFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Wallpaper()

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach($store.cards) { $card in
                        CardView(card: $card, store: store, hub: hub, notes: notes)
                            .zIndex(card.z)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onAppear { clamp(to: geo.size) }
                .onChange(of: geo.size) { clamp(to: geo.size) }
            }
            .padding(.top, 28) // clear the traffic lights

            HStack(alignment: .bottom, spacing: 12) {
                GitHubStatusBar()
                Spacer(minLength: 12)
                VStack(spacing: 8) {
                    if voice.phase != .idle { voiceHUD }
                    commandBar
                }
                Spacer(minLength: 12)
                ClaudeUsageBar()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .animation(Self.tidySpring, value: voice.phase)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .cnvsNewTerminal)) { _ in
            withAnimation(Self.tidySpring) { store.addTerminal() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cnvsFocusCommandBar)) { _ in
            commandFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cnvsTidy)) { _ in
            tidy()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cnvsOpenPhoneTerminal)) { _ in
            openPhoneTerminals()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cnvsVoiceToggle)) { _ in
            voice.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cnvsWakeToggle)) { _ in
            voice.toggleWake()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cnvsSimulatorToggle)) { _ in
            withAnimation(Self.tidySpring) { store.togglePanel(.simulator) }
        }
        .onAppear {
            openPhoneTerminals()
            wireVoice()
            voice.resumeWakeIfEnabled()
        }
    }

    static let tidySpring = Animation.spring(response: 0.35, dampingFraction: 0.85)

    private func tidy() {
        withAnimation(Self.tidySpring) {
            store.tidy()
        }
    }

    /// Terminals the phone asked for via cnvs://terminal?session=… — the pane
    /// attaches to the listener-created tmux session, so the phone's ttyd
    /// viewer and this pane are the same shell.
    private func openPhoneTerminals() {
        for session in PhoneTerminalRequests.shared.drain() {
            // Both transports can announce the same session — one card each.
            guard !store.cards.contains(where: { $0.session == session }) else { continue }
            withAnimation(Self.tidySpring) {
                store.addTerminal(title: "phone·\(session.suffix(4))", session: session)
            }
        }
    }

    @State private var lastSize: CGSize?

    /// Scale the whole layout with the window (fullscreen shouldn't strand
    /// cards in a corner), then keep everything inside the visible frame.
    private func clamp(to size: CGSize) {
        guard size.width > 300, size.height > 200 else { return }
        defer { lastSize = size }
        store.canvasSize = size

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
                    withAnimation(Self.tidySpring) {
                        store.addTerminal(bootCommand: "claude " + prompt.shellQuoted)
                    }
                    commandText = ""
                    commandFocused = false
                }
            Text("⌘K")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.headerText)

            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 16)

            barButton("terminal.fill", help: "new terminal (⌘T)") {
                withAnimation(Self.tidySpring) { store.addTerminal() }
            }
            barButton("music.note", help: "toggle player") {
                withAnimation(Self.tidySpring) { store.togglePanel(.player) }
            }
            barButton("note.text", help: "toggle notes") {
                withAnimation(Self.tidySpring) { store.togglePanel(.notes) }
            }
            barButton("iphone", help: "toggle simulator (⌘I)") {
                withAnimation(Self.tidySpring) { store.togglePanel(.simulator) }
            }
            barButton("square.grid.3x3", help: "tidy — snap to grid (⌘G)") { tidy() }
            barButton(voice.phase == .listening ? "mic.fill" : "mic",
                      help: "voice (⌥Space)") { voice.toggle() }
            barButton(voice.wakeEnabled ? "ear.fill" : "ear",
                      help: "wake word — say \"agent\" (⌥⇧Space)") { voice.toggleWake() }
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

    // MARK: - Voice

    private var voiceHUD: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                switch voice.phase {
                case .listening:
                    Circle()
                        .fill(Color(red: 0.95, green: 0.35, blue: 0.35))
                        .frame(width: 7, height: 7)
                    Text("listening — tap to send")
                        .foregroundStyle(Theme.headerText)
                case .routing:
                    ProgressView().controlSize(.mini)
                    Text("routing…")
                        .foregroundStyle(Theme.headerText)
                case .done(let summary):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55))
                    Text(summary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(message)
                case .idle:
                    EmptyView()
                }
                Spacer(minLength: 0)
                Text("⌥Space")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.headerText)
            }
            .font(Theme.mono(11))
            .foregroundStyle(.white.opacity(0.9))

            // Full live transcript — the box grows with what he's saying.
            if voice.phase == .listening || voice.phase == .routing,
               !voice.transcript.isEmpty {
                Text(voice.transcript)
                    .font(Theme.mono(11))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // After routing: what it heard, what it thought, what it sent.
            if case .done = voice.phase {
                if !voice.transcript.isEmpty {
                    Text("“\(voice.transcript)”")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.headerText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let thought = voice.lastIntent?.thought, !thought.isEmpty {
                    Text(thought)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.accent.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let payload = voicePayload {
                    Text(payload)
                        .font(Theme.mono(11))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            if case .failed = voice.phase, !voice.transcript.isEmpty {
                Text("“\(voice.transcript)”")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.headerText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 560)
        .cardSurface()
        .contentShape(Rectangle())
        .onTapGesture {
            switch voice.phase {
            case .listening: voice.toggle()   // finish early, send now
            case .done, .failed: voice.dismiss()
            default: break
            }
        }
    }

    /// The exact text that got typed somewhere — verbatim words, or note line.
    private var voicePayload: String? {
        guard let intent = voice.lastIntent else { return nil }
        switch intent.action {
        case "terminal_send", "terminal_new":
            let dir = intent.cwd.map { URL(fileURLWithPath: $0).lastPathComponent + " › " } ?? ""
            guard let sent = voice.lastSent else { return intent.cwd.map { "shell in \($0)" } }
            return dir + sent
        case "note":
            return intent.noteText
        default:
            return nil
        }
    }

    /// Hand the router a snapshot of the workspace and the executor that
    /// carries out whatever it decides.
    private func wireVoice() {
        voice.gatherContext = { [weak store, weak hub, weak notes] in
            guard let store, let hub, let notes else { return "" }
            let terminals: [(id: String, title: String, session: String?)] = store.cards
                .filter { $0.kind == .terminal }
                .map { (String($0.id.uuidString.prefix(8)).lowercased(), $0.title, $0.session) }
            let source = hub.source
            let radioState = "\(hub.radio.isPlaying ? "playing" : "paused")\(hub.radio.isMuted ? ", muted" : "")"
            let tracks = hub.music.tracks.map { "\($0.index): \($0.title) — \($0.artist)" }
            let stations = hub.music.stations.map(\.name)
            let nowPlaying = hub.music.hasTrack
                ? "\(hub.music.title) — \(hub.music.artist) (\(hub.music.isPlaying ? "playing" : "paused"))"
                : "nothing"
            let noteNames = notes.notes.map(\.name)

            return await Task.detached {
                var out = "TERMINALS (id · title · cwd · recent output):\n"
                if terminals.isEmpty { out += "  none open\n" }
                for t in terminals {
                    var cwd = "?"
                    var tail = ""
                    if let s = t.session {
                        cwd = TerminalRegistry.tmuxOutput(
                            ["display-message", "-p", "-t", "=" + s, "#{pane_current_path}"]
                        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                        let lines = (TerminalRegistry.tmuxOutput(["capture-pane", "-p", "-t", "=" + s]) ?? "")
                            .split(separator: "\n", omittingEmptySubsequences: true)
                            .suffix(10)
                            .map { String($0.prefix(160)) }
                        tail = lines.joined(separator: "\n    ")
                    }
                    out += "- id \(t.id) · \(t.title) · \(cwd)\n    \(tail)\n"
                }
                out += "\nPROJECTS he can open a terminal in:\n"
                out += VoiceController.listProjects().map { "- \($0)" }.joined(separator: "\n")
                out += "\n\nMEDIA CARD — showing: \(source.label)\n"
                out += "- claude fm (YouTube livestream, \(radioState)): play/pause/mute only, "
                out += "nothing to skip.\n"
                out += "- soundcloud: now \(nowPlaying)\n  Stations: \(stations.joined(separator: ", "))\n"
                out += "  Tracks:\n  " + (tracks.isEmpty ? "(none loaded)" : tracks.joined(separator: "\n  "))
                out += "\n\nNOTES: \(noteNames.joined(separator: ", "))"
                return out
            }.value
        }

        voice.execute = { intent, spoken in
            runVoiceIntent(intent, spoken: spoken)
        }
    }

    private func runVoiceIntent(_ intent: VoiceIntent, spoken: String) -> String {
        // His words go through untouched. "text" only carries the PREVIOUS
        // turn's words after a clarifying exchange — never a rewrite.
        let words = (intent.text?.isEmpty == false ? intent.text! : spoken)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch intent.action {
        case "terminal_send":
            guard let idPrefix = intent.terminalID?.lowercased(),
                  let card = store.cards.first(where: {
                      $0.kind == .terminal && $0.id.uuidString.lowercased().hasPrefix(idPrefix)
                  })
            else { return "couldn't find that terminal" }
            guard !words.isEmpty else { return "nothing to send" }
            var text = words
            if intent.wrapClaude {
                var cmd = "claude"
                if let model = intent.claudeModel, ["haiku", "sonnet", "opus"].contains(model) {
                    cmd += " --model " + model
                }
                text = cmd + " " + words.shellQuoted
            }
            store.raise(card.id)
            voice.lastSent = text
            TerminalRegistry.shared.send(to: card.id, text: text + "\r")
            return intent.summary.isEmpty ? "→ \(card.title)" : intent.summary

        case "terminal_new":
            var parts: [String] = []
            if let cwd = intent.cwd, !cwd.isEmpty { parts.append("cd " + cwd.shellQuoted) }
            if intent.wrapClaude, !words.isEmpty {
                var cmd = "claude"
                if let model = intent.claudeModel, ["haiku", "sonnet", "opus"].contains(model) {
                    cmd += " --model " + model
                }
                cmd += " " + words.shellQuoted
                parts.append(cmd)
            }
            let title = intent.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            voice.lastSent = parts.last
            withAnimation(Self.tidySpring) {
                store.addTerminal(
                    bootCommand: parts.isEmpty ? nil : parts.joined(separator: " && "),
                    title: title
                )
            }
            return intent.summary.isEmpty ? "new terminal" : intent.summary

        case "player":
            // Anything that names tracks or playlists is SoundCloud by
            // definition; the livestream only takes transport commands.
            switch intent.playerAction {
            case "radio": hub.select(.radio); hub.radio.catchUp()
            case "soundcloud": hub.select(.soundcloud)
            case "mute": hub.radio.setMuted(true)
            case "unmute": hub.radio.setMuted(false)
            case "toggle":
                hub.source == .radio ? hub.radio.toggle() : hub.music.toggle()
            case "play":
                hub.source == .radio ? hub.radio.catchUp() : hub.music.toggle()
            case "pause":
                hub.source == .radio ? hub.radio.pause() : hub.music.pause()
            case "next":
                guard hub.source == .soundcloud else { return "claude fm is a livestream — nothing to skip" }
                hub.music.next()
            case "prev":
                guard hub.source == .soundcloud else { return "claude fm is a livestream — nothing to skip" }
                hub.music.prev()
            case "play_track":
                guard let index = intent.trackIndex else { return "which track?" }
                hub.select(.soundcloud)
                hub.music.skip(to: index)
            case "station":
                guard let name = intent.station?.lowercased(),
                      let match = hub.music.stations.first(where: {
                          $0.name.lowercased().contains(name)
                      })
                else { return "no station like that" }
                hub.select(.soundcloud)
                hub.music.select(match)
            default: return "unknown player action"
            }
            return intent.summary.isEmpty ? hub.source.label : intent.summary

        case "note":
            guard let text = intent.noteText else { return "nothing to note" }
            return notes.append(text, title: intent.noteTitle, toNoteNamed: intent.noteTarget)

        default:
            return intent.say ?? (intent.summary.isEmpty ? "not sure what to do" : intent.summary)
        }
    }
}

struct CardView: View {
    @Binding var card: Card
    let store: WorkspaceStore
    @ObservedObject var hub: PlayerHub
    let notes: NotesStore

    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGSize?

    /// The livestream is 16:9 and the card rarely is — so the radio card drops
    /// its glass entirely and the video floats on the wallpaper instead of
    /// sitting in black bars.
    private var floating: Bool { card.kind == .player && hub.source == .radio }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: card.width, height: card.height)
        .cardSurface(clear: floating)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .offset(x: card.x, y: card.y)
        .simultaneousGesture(
            TapGesture().onEnded {
                store.raise(card.id)
                if card.kind == .simulator { SimulatorDockController.shared.raise() }
            }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(kindColor).frame(width: 7, height: 7)
            if card.kind == .player {
                PlayerSourceChips(hub: hub)
            } else {
                Text(card.title)
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Theme.headerText)
            }
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
        .background(Color.white.opacity(floating ? 0 : 0.03))
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
            TerminalPane(cardID: card.id, session: card.session, bootCommand: card.bootCommand)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: Theme.cardRadius,
                        bottomTrailingRadius: Theme.cardRadius
                    )
                )
        case .player:
            PlayerHostView(hub: hub)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: floating ? 0 : Theme.cardRadius,
                        bottomTrailingRadius: floating ? 0 : Theme.cardRadius
                    )
                )
        case .notes:
            NotesCardView(store: notes)
        case .simulator:
            SimulatorDockView()
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: Theme.cardRadius,
                        bottomTrailingRadius: Theme.cardRadius
                    )
                )
        }
    }

    private var kindColor: Color {
        switch card.kind {
        case .terminal: return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .player: return Theme.accent
        case .notes: return Color(red: 0.55, green: 0.65, blue: 0.95)
        case .simulator: return Color(red: 0.95, green: 0.55, blue: 0.35)
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
