import SwiftUI
import AVFoundation
import Speech

/// One decoded routing decision from the voice agent. Fields are sparse —
/// only the ones relevant to `action` arrive from the model.
struct VoiceIntent {
    var action = "answer"
    var summary = ""
    var thought: String?
    // terminal_send
    var terminalID: String?
    var text: String?
    /// True when the pane/new shell should launch `claude '<words>'`; false
    /// when the words drop straight into an already-running claude REPL.
    var wrapClaude = true
    // terminal_new
    var cwd: String?
    var claudeModel: String?
    var prompt: String?
    // media card (claude fm radio + soundcloud)
    var playerAction: String?
    var trackIndex: Int?
    var station: String?
    // note
    var noteText: String?
    var noteTitle: String?
    var noteTarget: String?
    // answer
    var say: String?

    init(json: [String: Any]) {
        action = json["action"] as? String ?? "answer"
        summary = json["summary"] as? String ?? ""
        thought = json["thought"] as? String
        terminalID = json["terminal_id"] as? String
        text = json["text"] as? String
        wrapClaude = json["wrap_claude"] as? Bool ?? true
        cwd = json["cwd"] as? String
        claudeModel = json["claude_model"] as? String
        prompt = json["prompt"] as? String
        playerAction = json["player_action"] as? String
        trackIndex = json["track_index"] as? Int
        station = json["station"] as? String
        noteText = json["note_text"] as? String
        noteTitle = json["note_title"] as? String
        noteTarget = json["note_target"] as? String
        say = json["say"] as? String
    }
}

/// ⌥Space toggles capture: beep, live on-device transcription, auto-stop on
/// silence, then a FreeLLMAPI router decides which surface the words drive
/// (existing terminal / new terminal / player / notes) and RootView executes.
@MainActor
final class VoiceController: ObservableObject {
    enum Phase: Equatable {
        case idle, listening, routing
        case done(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle {
        didSet { if phase == .idle { maybeResumeWake() } }
    }
    @Published var transcript = ""
    /// Last routed decision — the HUD shows its thought + payload after done.
    @Published var lastIntent: VoiceIntent?
    /// Exact text the executor typed somewhere — HUD payload.
    @Published var lastSent: String?
    /// Wake-word mode: mic stays hot, saying "agent" starts a capture.
    @Published var wakeEnabled = UserDefaults.standard.bool(forKey: "cnvs.voice.wakeEnabled") {
        didSet { UserDefaults.standard.set(wakeEnabled, forKey: "cnvs.voice.wakeEnabled") }
    }

    /// Set by RootView: workspace snapshot the router reasons over.
    var gatherContext: () async -> String = { "" }
    /// Set by RootView: performs the intent with the verbatim transcript,
    /// returns a short HUD line.
    var execute: (VoiceIntent, String) -> String = { _, _ in "no executor wired" }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var lastChange = Date()
    private var startedAt = Date()
    private var resetWork: DispatchWorkItem?
    private var wakeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var wakeTask: SFSpeechRecognitionTask?
    private var wakeTimer: Timer?
    private var wakeStartedAt = Date()
    private var wakeActive = false
    // Double-clap wake: sharp transients well above the room's rolling level.
    private var clapTimes: [Date] = []
    private var roomLevel: Float = 0.05
    private static let clapPeakFloor: Float = 0.35
    private static let clapPairWindow = 0.12...0.9
    /// Last exchange kept so "the second one" style follow-ups can resolve.
    private var history: [[String: String]] = []

    // MARK: - Capture lifecycle

    func toggle() {
        switch phase {
        case .idle, .done, .failed: start()
        case .listening: finishCapture()
        case .routing: break
        }
    }

    private func start() {
        resetWork?.cancel()
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self?.fail("speech recognition not authorized (System Settings → Privacy)")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        granted ? self?.beginCapture() : self?.fail("mic access denied")
                    }
                }
            }
        }
    }

    // MARK: - Wake word ("agent")

    func toggleWake() {
        wakeEnabled.toggle()
        if wakeEnabled {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard status == .authorized else {
                        self?.wakeEnabled = false
                        self?.fail("speech recognition not authorized (System Settings → Privacy)")
                        return
                    }
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            if granted {
                                self?.startWakeLoop()
                            } else {
                                self?.wakeEnabled = false
                                self?.fail("mic access denied")
                            }
                        }
                    }
                }
            }
        } else {
            stopWakeAudio()
        }
    }

    /// Called on launch by RootView so a persisted preference resumes.
    func resumeWakeIfEnabled() {
        guard wakeEnabled else { return }
        wakeEnabled = false
        toggleWake()
    }

    private func maybeResumeWake() {
        guard wakeEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.wakeEnabled, self.phase == .idle, !self.wakeActive else { return }
            self.startWakeLoop()
        }
    }

    /// Continuous low-key recognition that only watches for the wake word.
    /// On-device dictation sessions die after ~1 min, so the request is
    /// recycled every 50s and after every final/error.
    private func startWakeLoop() {
        guard wakeEnabled, phase == .idle, !wakeActive else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
                ?? SFSpeechRecognizer(),
              recognizer.isAvailable
        else { wakeEnabled = false; fail("speech recognizer unavailable"); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        wakeRequest = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { wakeEnabled = false; fail("no microphone input"); return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            // Peak level per ~21ms buffer feeds the double-clap detector.
            guard let data = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
            DispatchQueue.main.async { self?.registerLevel(peak) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            wakeEnabled = false
            fail("audio engine: \(error.localizedDescription)")
            return
        }

        wakeActive = true
        wakeStartedAt = Date()

        wakeTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.wakeActive else { return }
                if let result {
                    let words = result.bestTranscription.formattedString.lowercased()
                        .split { !$0.isLetter }
                    if words.last == "agent" {
                        self.stopWakeAudio()
                        self.beginCapture()
                        return
                    }
                }
                // Session ended on its own (silence-final or error) — recycle.
                if error != nil || (result?.isFinal ?? false) {
                    self.recycleWake()
                }
            }
        }

        wakeTimer?.invalidate()
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.wakeActive else { return }
                if Date().timeIntervalSince(self.wakeStartedAt) > 50 { self.recycleWake() }
            }
        }
    }

    /// Two claps 0.12–0.9s apart wake the capture, same as saying "agent".
    /// A clap is a transient several times louder than the rolling room level.
    private func registerLevel(_ peak: Float) {
        guard wakeActive, phase == .idle else { return }
        let isSpike = peak > max(Self.clapPeakFloor, roomLevel * 4)
        roomLevel = roomLevel * 0.95 + peak * 0.05
        guard isSpike else { return }

        let now = Date()
        if let last = clapTimes.last, now.timeIntervalSince(last) < Self.clapPairWindow.lowerBound {
            return // still the same clap's tail
        }
        clapTimes = clapTimes.filter { now.timeIntervalSince($0) < 1.2 } + [now]
        if clapTimes.count >= 2,
           let previous = clapTimes.dropLast().last,
           Self.clapPairWindow.contains(now.timeIntervalSince(previous)) {
            clapTimes = []
            stopWakeAudio()
            beginCapture()
        }
    }

    private func recycleWake() {
        stopWakeAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.wakeEnabled, self.phase == .idle else { return }
            self.startWakeLoop()
        }
    }

    private func stopWakeAudio() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        guard wakeActive || wakeTask != nil else { return }
        wakeActive = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        wakeRequest?.endAudio()
        wakeTask?.cancel()
        wakeTask = nil
        wakeRequest = nil
    }

    private func beginCapture() {
        stopWakeAudio()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
                ?? SFSpeechRecognizer(),
              recognizer.isAvailable
        else { fail("speech recognizer unavailable"); return }

        // Server-side recognition when available — noticeably more accurate
        // than the on-device model for full sentences; on-device stays the
        // wake-loop's job (single word, always-on, private).
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { fail("no microphone input"); return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            fail("audio engine: \(error.localizedDescription)")
            return
        }

        transcript = ""
        lastSent = nil
        phase = .listening
        lastChange = Date()
        startedAt = Date()
        Self.sound("Pop")

        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            DispatchQueue.main.async {
                guard self.phase == .listening else { return }
                self.transcript = result.bestTranscription.formattedString
                self.lastChange = Date()
                if result.isFinal { self.finishCapture() }
            }
        }

        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkSilence() }
        }
    }

    private func checkSilence() {
        guard phase == .listening else { return }
        let sinceChange = Date().timeIntervalSince(lastChange)
        let total = Date().timeIntervalSince(startedAt)
        if transcript.isEmpty {
            if total > 8 { stopAudio(); fail("heard nothing") }
        } else if sinceChange > 2.8 || total > 60 {
            finishCapture()
        }
    }

    private func stopAudio() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func finishCapture() {
        guard phase == .listening else { return }
        stopAudio()
        Self.sound("Pop")
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { phase = .idle; return }
        phase = .routing
        Task { await route(spoken) }
    }

    private func fail(_ message: String) {
        stopAudio()
        Self.sound("Basso")
        phase = .failed(message)
        scheduleReset(after: 6)
    }

    private func scheduleReset(after seconds: Double) {
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .listening = self.phase { return }
            if case .routing = self.phase { return }
            self.phase = .idle
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func sound(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: - Routing agent

    private func route(_ spoken: String) async {
        guard let config = Self.loadConfig() else {
            fail("FREELLMAPI_KEY not found (env or ~/.config/cnvs/env)")
            return
        }
        let context = await gatherContext()
        let userMsg = "WORKSPACE:\n\(context)\n\nSPOKEN:\n\(spoken)"

        var messages: [[String: String]] = [["role": "system", "content": Self.routerSystem]]
        messages += history
        messages.append(["role": "user", "content": userMsg])

        guard let raw = await Self.chat(messages: messages, config: config) else {
            fail("router LLM unreachable")
            return
        }
        guard let json = Self.extractJSON(raw) else {
            fail("router returned no JSON")
            return
        }
        history = [["role": "user", "content": userMsg],
                   ["role": "assistant", "content": raw]]

        let intent = VoiceIntent(json: json)
        lastIntent = intent
        let summary = execute(intent, spoken)
        Self.sound(intent.action == "answer" ? "Pop" : "Glass")
        phase = .done(summary)
        // Leave content-heavy results up long enough to actually read.
        let hasPayload = intent.prompt != nil || intent.text != nil || intent.noteText != nil
        scheduleReset(after: intent.action == "answer" ? 10 : (hasPayload ? 12 : 4))
    }

    /// Tap-to-dismiss from the HUD.
    func dismiss() {
        resetWork?.cancel()
        if phase != .listening, phase != .routing { phase = .idle }
    }

    /// OpenAI-compatible /chat/completions against the FreeLLMAPI proxy,
    /// walking the free-model fallback chain until one answers.
    private static func chat(messages: [[String: String]], config: Config) async -> String? {
        let chain = ["gemini-2.5-flash", "llama-3.3-70b-versatile", "openai/gpt-oss-120b"]
        for model in chain {
            let body: [String: Any] = [
                "model": model,
                "messages": messages,
                "temperature": 0.2,
                "max_tokens": 700,
            ]
            guard let url = URL(string: config.baseURL + "/chat/completions"),
                  let data = try? JSONSerialization.data(withJSONObject: body)
            else { continue }
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.httpBody = data
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
            guard let (respData, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String,
                  !content.isEmpty
            else { continue }
            return content
        }
        return nil
    }

    /// Models wrap JSON in fences or prose; carve out the outermost object.
    private static func extractJSON(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end
        else { return nil }
        let slice = String(raw[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }

    // MARK: - Config

    struct Config { let baseURL: String; let key: String }

    static func loadConfig() -> Config? {
        let env = ProcessInfo.processInfo.environment
        var base = env["FREELLMAPI_BASE_URL"]
        var key = env["FREELLMAPI_KEY"]
        let home = FileManager.default.homeDirectoryForCurrentUser
        for rel in [".config/cnvs/env", "Desktop/hfjoandco/btc5m-edge-tester/.env"] {
            if key != nil && base != nil { break }
            guard let text = try? String(contentsOf: home.appendingPathComponent(rel), encoding: .utf8)
            else { continue }
            for line in text.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let k = kv[0].trimmingCharacters(in: .whitespaces)
                let v = kv[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if k == "FREELLMAPI_BASE_URL", base == nil { base = v }
                if k == "FREELLMAPI_KEY", key == nil { key = v }
            }
        }
        guard let key, !key.isEmpty else { return nil }
        var b = base ?? "https://freellmapi-production-b5b1.up.railway.app/v1"
        while b.hasSuffix("/") { b.removeLast() }
        return Config(baseURL: b, key: key)
    }

    /// Projects the router can cd into — top-level folders of ~/Desktop/hfjoandco.
    nonisolated static func listProjects() -> [String] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/hfjoandco")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.path }
            .sorted()
    }

    private static let routerSystem = """
    You are the voice router inside CNVS, Harrison's floating terminal workspace on macOS. \
    He spoke a command. Decide which surface it drives and reply with ONE JSON object — no prose, no fences.

    Surfaces: existing terminals (tmux panes, each either at a zsh prompt or inside an \
    interactive claude REPL — read its tail), new terminals (optionally cd into a project \
    and launch the claude CLI), one media card that shows EITHER the Claude FM livestream \
    or his SoundCloud playlists, and markdown notes.

    YOU DO NOT WRITE OR EDIT PROMPTS. The app types his transcript into the target verbatim — \
    you never see-edit-rewrite-polish-shorten-expand his words. You are a dispatcher: decide \
    WHERE the words go, which claude model fits, and whether the pane needs a `claude` launch. \
    That is all.

    Schema (include "action", "thought" and "summary" always; other fields only when relevant):
    {
      "action": "terminal_send" | "terminal_new" | "player" | "note" | "answer",
      "thought": "<= 20 words: what he wants and why this route — shown to him in the HUD",
      "summary": "<= 8 word HUD line describing what you did",
      "terminal_id": "<id from WORKSPACE terminal list>",
      "wrap_claude": true | false,
      "cwd": "/absolute/project/path",
      "claude_model": "haiku" | "sonnet" | "opus",
      "text": "<ONLY on a follow-up turn: his original words from the previous turn, copied verbatim>",
      "player_action": "toggle" | "play" | "pause" | "mute" | "unmute" | "next" | "prev" \
    | "play_track" | "station" | "radio" | "soundcloud",
      "track_index": <int from the track list>,
      "station": "<station name>",
      "note_text": "<text to append>",
      "note_title": "<3-6 word title for a new note — REQUIRED when no note_target>",
      "note_target": "<existing note name>",
      "say": "<short reply or clarifying question>"
    }

    Rules:
    - Harrison is the developer of everything here — route commands as work orders, never \
    downgrade to "wanting advice" when judging intent.
    - Prefer terminal_send to an existing terminal when its title, cwd, or tail matches what \
    he's describing. wrap_claude: false when that pane's tail shows a claude REPL already \
    running (his words drop straight in); true when it shows a shell prompt (app runs \
    claude '<his words>').
    - Otherwise terminal_new: "cwd" from the PROJECTS list when he names one. wrap_claude \
    true unless he explicitly wants a plain shell.
    - claude_model: haiku = trivial/quick question, sonnet = normal coding, opus = hard \
    architecture or debugging; omit when unsure.
    - "text" exists ONLY for follow-up turns where his previous command needed clarification: \
    copy the previous turn's spoken words verbatim so they aren't lost. It is never a rewrite.
    - Music: action "player". "claude fm"/"the radio"/"the stream" → radio; \
    "soundcloud"/"my playlists" → soundcloud. play/pause/mute hit whichever source is \
    showing. Naming a song → play_track with the best index; naming a playlist → station; \
    "skip"/"next" → next (both switch the card to soundcloud — the livestream has nothing \
    to skip).
    - note ONLY when he explicitly says note/notes/write down/remember this. Anything \
    describing work he wants done — however rambly or excited — is a work order for a \
    terminal, not a note. When in doubt between note and terminal, pick terminal. \
    note_text may drop only the spoken preamble, nothing else. note_target only when he \
    names an existing note; otherwise ALWAYS include note_title — a specific 3-6 word \
    title from the content (each capture becomes its own dated note file).
    - Ambiguous target → action "answer" with a <= 10 word question in "say". \
    His next capture may be the answer — then route the original words via "text".
    """
}
