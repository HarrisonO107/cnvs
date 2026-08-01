import SwiftUI
import WebKit

/// Claude FM — Anthropic's 24/7 YouTube livestream (youtube.com/@claude/live),
/// embedded as the only thing in the card: no station list, no transport rail,
/// no YouTube chrome. The stream's own overlay names the artist and track.
@MainActor
final class RadioModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var isPlaying = false
    @Published var isMuted = false
    @Published var isReady = false
    @Published var status = "tuning in…"

    let webView: WKWebView

    /// The live broadcast rotates video IDs whenever Anthropic restarts it, so
    /// the ID is resolved from the channel's /live page at launch. This one is
    /// the fallback when that lookup fails (offline, markup change).
    static let fallbackVideoID = "tRsQsTMvPNg"
    static let liveURL = "https://www.youtube.com/@claude/live"
    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    private var videoID: String?
    private var retunes = 0
    /// The live-ID lookup and the page load race each other; whichever loses
    /// hands off through here so `tune()` never fires into an empty document.
    private var pageLoaded = false
    private var pendingID: String?

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 360), configuration: config)
        super.init()
        config.userContentController.add(self, name: "radio")
        webView.underPageBackgroundColor = .clear
        // Without this the page paints opaque white, so the 16:9 letterbox
        // reads as two white slabs instead of wallpaper. Guarded: it is a
        // private setter, so a future WebKit that drops it just goes back to
        // painting a background.
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        // YouTube serves a dead embed ("Error code: 152") to WebKit's default
        // UA string; a Safari UA gets the real player.
        webView.customUserAgent = Self.safariUA
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.bridgeHTML, baseURL: URL(string: "https://cnvs.local"))
        Task { await tune() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            pageLoaded = true
            if let id = pendingID { pendingID = nil; send(id) }
        }
    }

    /// Resolve the currently-live video and hand it to the page.
    func tune() async {
        let id = await Self.resolveLiveVideoID() ?? Self.fallbackVideoID
        videoID = id
        status = "connecting…"
        if pageLoaded { send(id) } else { pendingID = id }
    }

    private func send(_ id: String) {
        webView.evaluateJavaScript("tune(\(Self.jsString(id)))")
    }

    func toggle() { webView.evaluateJavaScript("toggle()") }
    func play() { webView.evaluateJavaScript("play()") }
    func pause() { webView.evaluateJavaScript("pause()") }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        webView.evaluateJavaScript("setMuted(\(muted))")
    }

    /// Jump back to the live edge after a pause.
    func catchUp() { webView.evaluateJavaScript("live(); play()") }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["t"] as? String else { return }
        Task { @MainActor in
            switch type {
            case "ready":
                isReady = true
            case "state":
                // YT: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
                let s = body["s"] as? Int ?? -1
                isPlaying = (s == 1)
                switch s {
                case 1: status = "live"
                case 3: status = "buffering…"
                case 2: status = "paused"
                case 0: status = "stream ended"
                default: break
                }
                if s == 0 { await retune() }     // restarted broadcast → new ID
            case "muted":
                isMuted = (body["v"] as? Bool) ?? false
            case "error":
                status = "stream moved — retuning…"
                await retune()
            default: break
            }
        }
    }

    /// A dead ID means the broadcast restarted; re-resolve, but not forever.
    private func retune() async {
        guard retunes < 3 else {
            status = "claude fm is offline"
            return
        }
        retunes += 1
        try? await Task.sleep(for: .seconds(2))
        await tune()
    }

    private static func resolveLiveVideoID() async -> String? {
        guard let url = URL(string: liveURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        // The /live page canonicalises to the broadcast that is on air now.
        guard let re = try? NSRegularExpression(pattern: "watch\\?v=([A-Za-z0-9_-]{11})"),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(m.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    /// Letterboxed 16:9 iframe, nothing else on the page. `pointer-events:none`
    /// keeps the mouse off the embed so YouTube never fades its own title bar
    /// and share buttons in — CNVS draws the only controls.
    static let bridgeHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      html,body{margin:0;height:100%;background:transparent;overflow:hidden}
      #wrap{position:absolute;inset:0;display:flex;align-items:center;justify-content:center}
      #frame{position:relative;width:min(100%, calc(100vh * 16 / 9));aspect-ratio:16/9;pointer-events:none}
      iframe{position:absolute;inset:0;width:100%;height:100%;border:0}
    </style></head>
    <body><div id="wrap"><div id="frame"><div id="yt"></div></div></div>
    <script src="https://www.youtube.com/iframe_api"></script>
    <script>
    let player = null, wanted = null;
    function post(m){ try { window.webkit.messageHandlers.radio.postMessage(m) } catch(e){} }
    function onYouTubeIframeAPIReady(){ if (wanted) mount(wanted); }
    function tune(id){
      wanted = id;
      if (window.YT && YT.Player) mount(id);
    }
    function mount(id){
      if (player && player.loadVideoById) { player.loadVideoById(id); return; }
      player = new YT.Player('yt', {
        videoId: id,
        playerVars: {autoplay:1, controls:0, modestbranding:1, rel:0, playsinline:1,
                     iv_load_policy:3, disablekb:1, fs:0},
        events: {
          onReady: e => {
            e.target.playVideo();
            post({t:'ready'});
            // If the embed refuses to autoplay with sound, fall back to muted
            // playback rather than a frozen frame — CNVS shows an unmute dot.
            setTimeout(() => {
              if (player.getPlayerState && player.getPlayerState() !== 1) {
                player.mute(); player.playVideo(); post({t:'muted', v:true});
              }
            }, 1800);
          },
          onStateChange: e => post({t:'state', s:e.data}),
          onError: e => post({t:'error', code:e.data})
        }
      });
    }
    function play(){ if (player) player.playVideo() }
    function pause(){ if (player) player.pauseVideo() }
    function toggle(){
      if (!player) return;
      player.getPlayerState() === 1 ? player.pauseVideo() : player.playVideo();
    }
    function setMuted(m){ if (player) m ? player.mute() : player.unMute() }
    function live(){ if (player && player.getDuration) player.seekTo(player.getDuration(), true) }
    </script></body></html>
    """
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct RadioCardView: View {
    @ObservedObject var model: RadioModel
    @State private var hovering = false

    var body: some View {
        ZStack {
            WebViewHost(webView: model.webView)
                .opacity(model.isReady ? 1 : 0)

            if !model.isReady {
                VStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                    Text(model.status)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.headerText)
                }
            }

            // Hover-only controls: the stream is the whole card until he
            // reaches for it.
            VStack {
                Spacer()
                controls
                    .opacity(hovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.18), value: hovering)
            }
            .padding(10)
        }
        .onHover { hovering = $0 }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: { model.toggle() }) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button(action: { model.setMuted(!model.isMuted) }) {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.isMuted ? Theme.accent : .white.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isMuted ? "unmute" : "mute")

            HStack(spacing: 5) {
                Circle()
                    .fill(model.isPlaying ? Color(red: 0.95, green: 0.35, blue: 0.35) : Theme.headerText)
                    .frame(width: 6, height: 6)
                Text(model.isPlaying ? "CLAUDE FM · LIVE" : model.status.uppercased())
                    .font(Theme.mono(9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }

            Spacer(minLength: 0)

            Button(action: { Task { await model.tune() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.headerText)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("retune to the live edge")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}
