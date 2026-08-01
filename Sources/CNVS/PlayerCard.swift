import SwiftUI
import WebKit

struct Station: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String
}

struct Track: Identifiable, Equatable {
    let index: Int
    let title: String
    let artist: String
    let durMS: Double
    var id: Int { index }
}

@MainActor
final class PlayerModel: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var artworkURL: URL?
    @Published var isPlaying = false
    @Published var progress: Double = 0 // 0..1
    @Published var durationMS: Double = 0
    @Published var positionMS: Double = 0
    @Published var hasTrack = false
    @Published var stations: [Station] = []
    @Published var currentStationID: UUID?
    @Published var addingStation = false
    @Published var tracks: [Track] = []
    @Published var currentIndex: Int?

    let webView: WKWebView

    private static let lastURLKey = "cnvs.player.lastURL"
    private static let stationsKey = "cnvs.player.stations"

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 180), configuration: config)
        super.init()
        config.userContentController.add(self, name: "player")
        webView.loadHTMLString(Self.bridgeHTML, baseURL: URL(string: "https://cnvs.local"))

        if let data = UserDefaults.standard.data(forKey: Self.stationsKey),
           let saved = try? JSONDecoder().decode([Station].self, from: data) {
            stations = saved
        }
        // Migrate a link pasted before stations existed.
        if stations.isEmpty,
           let last = UserDefaults.standard.string(forKey: Self.lastURLKey),
           !last.isEmpty {
            Task { await self.addStation(urlString: last, andPlay: false) }
        }
        // Repair names saved before title cleanup existed ("?", "house by harrison", …).
        Task { await self.refreshStationNames() }
    }

    // MARK: stations

    func addStation(urlString: String, andPlay: Bool = true) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("soundcloud.com") else { return }
        guard !stations.contains(where: { $0.url == trimmed }) else {
            if andPlay, let existing = stations.first(where: { $0.url == trimmed }) {
                select(existing)
            }
            return
        }
        let name = await Self.fetchCleanTitle(for: trimmed) ?? Self.nameFromSlug(trimmed)
        let station = Station(id: UUID(), name: name, url: trimmed)
        stations.append(station)
        saveStations()
        if andPlay { select(station) }
    }

    func refreshStationNames() async {
        for station in stations {
            if let clean = await Self.fetchCleanTitle(for: station.url), clean != station.name {
                renameStation(station, to: clean)
            }
        }
    }

    func select(_ station: Station) {
        currentStationID = station.id
        tracks = []
        currentIndex = nil
        load(urlString: station.url)
    }

    func removeStation(_ station: Station) {
        stations.removeAll { $0.id == station.id }
        if currentStationID == station.id { currentStationID = nil }
        saveStations()
    }

    func renameStation(_ station: Station, to newName: String) {
        guard let idx = stations.firstIndex(where: { $0.id == station.id }) else { return }
        stations[idx].name = newName
        saveStations()
    }

    private func saveStations() {
        if let data = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(data, forKey: Self.stationsKey)
        }
    }

    /// Playlist title via SoundCloud's public oEmbed endpoint, with the
    /// trailing "by <author>" stripped so a chip reads just "House".
    private static func fetchCleanTitle(for url: String) async -> String? {
        var comps = URLComponents(string: "https://soundcloud.com/oembed")!
        comps.queryItems = [.init(name: "format", value: "json"), .init(name: "url", value: url)]
        guard let endpoint = comps.url else { return nil }
        struct OEmbed: Decodable {
            let title: String?
            let author_name: String?
        }
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint),
              let embed = try? JSONDecoder().decode(OEmbed.self, from: data),
              var title = embed.title, !title.isEmpty else { return nil }
        if let author = embed.author_name, !author.isEmpty {
            for suffix in [" by \(author)", " – by \(author)", " - by \(author)"]
            where title.lowercased().hasSuffix(suffix.lowercased()) {
                title = String(title.dropLast(suffix.count))
            }
        }
        let cleaned = Self.stripDecorations(title)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// "House 🔗" → "House": drop emoji/symbols from the ends, keep words.
    private static func stripDecorations(_ s: String) -> String {
        var chars = Array(s)
        while let f = chars.first, !(f.isLetter || f.isNumber) { chars.removeFirst() }
        while let l = chars.last, !(l.isLetter || l.isNumber) { chars.removeLast() }
        return String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nameFromSlug(_ url: String) -> String {
        let slug = url.split(separator: "?").first
            .flatMap { $0.split(separator: "/").last }
            .map(String.init) ?? "playlist"
        let name = stripDecorations(slug.replacingOccurrences(of: "-", with: " "))
        return name.isEmpty ? "playlist" : name
    }

    // MARK: playback

    func load(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("soundcloud.com") else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.lastURLKey)
        webView.evaluateJavaScript("load(\(Self.jsString(trimmed)))")
        hasTrack = true
    }

    func toggle() { webView.evaluateJavaScript("toggle()") }
    /// Used when the card switches to Claude FM — two audio sources must never
    /// play over each other.
    func pause() { webView.evaluateJavaScript("pauseIt()") }
    func next() { webView.evaluateJavaScript("next()") }
    func prev() { webView.evaluateJavaScript("prev()") }
    func skip(to index: Int) { webView.evaluateJavaScript("skipTo(\(index))") }

    func seek(to fraction: Double) {
        webView.evaluateJavaScript("seekRel(\(max(0, min(1, fraction))))")
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["t"] as? String else { return }
        Task { @MainActor in
            switch type {
            case "play": isPlaying = true
            case "pause": isPlaying = false
            case "finish":
                progress = 0
            case "progress":
                if let ms = body["ms"] as? Double {
                    positionMS = ms
                    if durationMS > 0 { progress = ms / durationMS }
                }
            case "sound":
                title = body["title"] as? String ?? ""
                artist = body["artist"] as? String ?? ""
                durationMS = body["dur"] as? Double ?? 0
                hasTrack = true
                if let art = body["art"] as? String, !art.isEmpty {
                    artworkURL = URL(string: art.replacingOccurrences(of: "-large", with: "-t500x500"))
                } else {
                    artworkURL = nil
                }
            case "sounds":
                if let items = body["items"] as? [[String: Any]] {
                    tracks = items.compactMap { item in
                        guard let i = item["i"] as? Int else { return nil }
                        return Track(
                            index: i,
                            title: item["title"] as? String ?? "",
                            artist: item["artist"] as? String ?? "",
                            durMS: item["dur"] as? Double ?? 0
                        )
                    }
                }
            case "index":
                currentIndex = body["ix"] as? Int
            default: break
            }
        }
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    static let bridgeHTML = """
    <!doctype html><html><head><meta charset="utf-8"></head>
    <body style="margin:0;background:transparent;overflow:hidden">
    <iframe id="sc" width="100%" height="166" frameborder="no" allow="autoplay" src="about:blank"></iframe>
    <script src="https://w.soundcloud.com/player/api.js"></script>
    <script>
    let widget = null;
    function post(m){ try { window.webkit.messageHandlers.player.postMessage(m) } catch(e){} }
    function bind(){
      widget.bind(SC.Widget.Events.READY, () => { sound(); sounds(); index(); });
      widget.bind(SC.Widget.Events.PLAY, () => { post({t:'play'}); sound(); index(); sounds(); });
      widget.bind(SC.Widget.Events.PAUSE, () => post({t:'pause'}));
      widget.bind(SC.Widget.Events.PLAY_PROGRESS, e => post({t:'progress', ms:e.currentPosition}));
      widget.bind(SC.Widget.Events.FINISH, () => post({t:'finish'}));
    }
    function load(url){
      const f = document.getElementById('sc');
      if (!widget) {
        f.src = 'https://w.soundcloud.com/player/?url=' + encodeURIComponent(url) + '&auto_play=true&visual=false&show_teaser=false';
        f.onload = () => { if (!widget) { widget = SC.Widget(f); bind(); } };
      } else {
        widget.load(url, {auto_play: true, callback: () => { sound(); sounds(); index(); }});
      }
    }
    function sound(){
      widget.getCurrentSound(s => {
        if (s) post({t:'sound', title:s.title||'', artist:(s.user&&s.user.username)||'', art:s.artwork_url||'', dur:s.duration||0});
      });
    }
    function sounds(){
      widget.getSounds(list => {
        post({t:'sounds', items:(list||[]).map((s,i) => ({
          i:i, title:(s&&s.title)||'', artist:(s&&s.user&&s.user.username)||'', dur:(s&&s.duration)||0
        }))});
      });
    }
    function index(){ widget.getCurrentSoundIndex(ix => post({t:'index', ix:ix})); }
    function toggle(){ if (widget) widget.toggle(); }
    function pauseIt(){ if (widget) widget.pause(); }
    function next(){ if (widget) widget.next(); }
    function prev(){ if (widget) widget.prev(); }
    function skipTo(i){ if (widget) widget.skip(i); }
    function seekRel(f){ if (widget) widget.getDuration(d => widget.seekTo(d*f)); }
    </script></body></html>
    """
}

struct PlayerCardView: View {
    @ObservedObject var model: PlayerModel
    @State private var urlField: String = ""
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            stationsRow

            if model.addingStation || model.stations.isEmpty {
                linkField
            }

            if model.hasTrack {
                nowPlaying
                transport
                if model.tracks.count > 1 {
                    trackList
                }
            } else {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.accent.opacity(0.6))
                        Text(model.stations.isEmpty
                             ? "add a soundcloud playlist"
                             : "pick a station")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.headerText)
                    }
                    Spacer()
                }
                Spacer()
            }

            WebViewHost(webView: model.webView)
                .frame(width: 2, height: 2)
                .opacity(0.01)
        }
        .padding(14)
    }

    private var stationsRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.stations) { station in
                        let active = model.currentStationID == station.id
                        Button(action: { model.select(station) }) {
                            Text(station.name)
                                .font(Theme.mono(10, weight: active ? .semibold : .regular))
                                .lineLimit(1)
                                .foregroundStyle(active ? Color.black.opacity(0.85) : .white.opacity(0.75))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(active ? Theme.accent : Color.white.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove") { model.removeStation(station) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: {
                model.addingStation.toggle()
                if model.addingStation { urlFocused = true }
            }) {
                Image(systemName: model.addingStation ? "xmark" : "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.headerText)
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.07))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("add playlist")
        }
    }

    private var linkField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 10))
                .foregroundStyle(Theme.headerText)
            TextField("Paste a SoundCloud playlist or track link…", text: $urlField)
                .textFieldStyle(.plain)
                .font(Theme.mono(11))
                .foregroundStyle(.white.opacity(0.85))
                .focused($urlFocused)
                .onSubmit {
                    let url = urlField
                    urlField = ""
                    model.addingStation = false
                    Task { await model.addStation(urlString: url) }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title.isEmpty ? "Loading…" : model.title)
                        .font(Theme.mono(12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(model.artist)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.headerText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            WaveformView(isPlaying: model.isPlaying, progress: model.progress)
                .frame(height: 22)
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            skipButton("backward.fill") { model.prev() }
            Button(action: { model.toggle() }) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            skipButton("forward.fill") { model.next() }

            Text(timeLabel)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.headerText)
                .monospacedDigit()

            ProgressBar(progress: model.progress) { model.seek(to: $0) }
                .frame(height: 4)
        }
    }

    private var trackList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(model.tracks) { track in
                        let current = model.currentIndex == track.index
                        Button(action: { model.skip(to: track.index) }) {
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", track.index + 1))
                                    .font(Theme.mono(9))
                                    .foregroundStyle(current ? Theme.accent : Theme.headerText.opacity(0.7))
                                Text(track.title.isEmpty ? "track \(track.index + 1)" : track.title)
                                    .font(Theme.mono(10, weight: current ? .semibold : .regular))
                                    .foregroundStyle(current ? Theme.accent : .white.opacity(0.80))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if current && model.isPlaying {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Theme.accent)
                                }
                                Text(fmt(track.durMS))
                                    .font(Theme.mono(9))
                                    .foregroundStyle(Theme.headerText.opacity(0.7))
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(current ? Color.white.opacity(0.07) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(track.index)
                    }
                }
            }
            .onChange(of: model.currentIndex) {
                if let ix = model.currentIndex {
                    withAnimation { proxy.scrollTo(ix, anchor: .center) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func skipButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var artwork: some View {
        Group {
            if let url = model.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.white.opacity(0.06)
                }
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "music.note")
                        .foregroundStyle(Theme.headerText)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }

    private func fmt(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var timeLabel: String {
        "\(fmt(model.positionMS)) / \(fmt(model.durationMS))"
    }
}

struct WaveformView: View {
    let isPlaying: Bool
    let progress: Double

    private let barCount = 36

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    let played = Double(i) / Double(barCount) <= progress
                    let base = 0.25 + 0.75 * abs(sin(Double(i) * 0.9 + 1.3))
                    let wobble = isPlaying ? 0.35 * sin(t * 6 + Double(i) * 0.7) : 0
                    let h = max(0.12, min(1.0, base + wobble))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(played ? Theme.accent : Color.white.opacity(0.18))
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: h, anchor: .center)
                }
            }
        }
    }
}

struct ProgressBar: View {
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(0, geo.size.width * progress))
            }
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { v in onSeek(v.location.x / geo.size.width) }
            )
        }
    }
}
