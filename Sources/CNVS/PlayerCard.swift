import SwiftUI
import WebKit

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

    let webView: WKWebView

    private static let lastURLKey = "cnvs.player.lastURL"

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 180), configuration: config)
        super.init()
        config.userContentController.add(self, name: "player")
        webView.loadHTMLString(Self.bridgeHTML, baseURL: URL(string: "https://cnvs.local"))
    }

    var lastURL: String {
        UserDefaults.standard.string(forKey: Self.lastURLKey) ?? ""
    }

    func load(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("soundcloud.com") else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.lastURLKey)
        let js = "load(\(Self.jsString(trimmed)))"
        webView.evaluateJavaScript(js)
        hasTrack = true
    }

    func toggle() { webView.evaluateJavaScript("toggle()") }

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
                isPlaying = false
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
      widget.bind(SC.Widget.Events.READY, () => { sound(); });
      widget.bind(SC.Widget.Events.PLAY, () => { post({t:'play'}); sound(); });
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
        widget.load(url, {auto_play: true, callback: () => { sound(); }});
      }
    }
    function sound(){
      widget.getCurrentSound(s => {
        if (s) post({t:'sound', title:s.title||'', artist:(s.user&&s.user.username)||'', art:s.artwork_url||'', dur:s.duration||0});
      });
    }
    function toggle(){ if (widget) widget.toggle(); }
    function seekRel(f){ if (widget) widget.getDuration(d => widget.seekTo(d*f)); }
    </script></body></html>
    """
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PlayerCardView: View {
    @ObservedObject var model: PlayerModel
    @State private var urlField: String = ""
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.headerText)
                TextField("Paste a SoundCloud link…", text: $urlField)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(.white.opacity(0.85))
                    .focused($urlFocused)
                    .onSubmit {
                        model.load(urlString: urlField)
                        urlFocused = false
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if model.hasTrack {
                HStack(alignment: .top, spacing: 14) {
                    artwork
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.title.isEmpty ? "Loading…" : model.title)
                            .font(Theme.mono(13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(2)
                        Text(model.artist)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.headerText)
                        Spacer(minLength: 4)
                        WaveformView(isPlaying: model.isPlaying, progress: model.progress)
                            .frame(height: 34)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button(action: { model.toggle() }) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 34, height: 34)
                            .background(Theme.accent)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Text(timeLabel)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.headerText)

                    ProgressBar(progress: model.progress) { model.seek(to: $0) }
                        .frame(height: 4)
                }
            } else {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                    Text("drop a soundcloud link above")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.headerText)
                }
                Spacer()
            }

            WebViewHost(webView: model.webView)
                .frame(width: 2, height: 2)
                .opacity(0.01)
        }
        .padding(12)
        .onAppear {
            if urlField.isEmpty { urlField = model.lastURL }
        }
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
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var timeLabel: String {
        func fmt(_ ms: Double) -> String {
            let s = Int(ms / 1000)
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return "\(fmt(model.positionMS)) / \(fmt(model.durationMS))"
    }
}

struct WaveformView: View {
    let isPlaying: Bool
    let progress: Double
    @State private var phase: Double = 0

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
