import SwiftUI

struct Note: Identifiable, Equatable {
    let id: URL
    var name: String
    var modified: Date
}

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var selected: Note?
    @Published var text: String = ""
    @Published var organizing = false
    @Published var organizeStatus: String?

    let dir: URL

    private var saveWork: DispatchWorkItem?

    init() {
        dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/CNVS/notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        seedIfEmpty()
        refresh()
    }

    private func seedIfEmpty() {
        let existing = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if existing.filter({ $0.pathExtension == "md" }).isEmpty {
            let welcome = dir.appendingPathComponent("welcome.md")
            try? "# CNVS notes\n\nDump thoughts here. Hit ✦ organize and Claude tidies, tags, and builds INDEX.md.\n"
                .write(to: welcome, atomically: true, encoding: .utf8)
        }
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        notes = urls
            .filter { $0.pathExtension == "md" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return Note(id: url, name: url.deletingPathExtension().lastPathComponent, modified: date)
            }
            .sorted { $0.modified > $1.modified }
        if let sel = selected, !notes.contains(where: { $0.id == sel.id }) {
            selected = nil
            text = ""
        }
    }

    func select(_ note: Note) {
        flushSave()
        selected = note
        text = (try? String(contentsOf: note.id, encoding: .utf8)) ?? ""
    }

    func newNote() {
        flushSave()
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        var url = dir.appendingPathComponent("note-\(stamp).md")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("note-\(stamp)-\(i).md")
            i += 1
        }
        try? "# \n".write(to: url, atomically: true, encoding: .utf8)
        refresh()
        if let note = notes.first(where: { $0.id == url }) { select(note) }
    }

    func rename(_ note: Note, to raw: String) {
        flushSave()
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        guard !cleaned.isEmpty, cleaned != note.name else { return }

        var url = dir.appendingPathComponent(cleaned).appendingPathExtension("md")
        var i = 2
        while url.path.lowercased() != note.id.path.lowercased(),
              FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(cleaned)-\(i)").appendingPathExtension("md")
            i += 1
        }

        let wasSelected = selected?.id == note.id
        do {
            try FileManager.default.moveItem(at: note.id, to: url)
        } catch { return }
        refresh()
        if wasSelected {
            selected = notes.first(where: { $0.id == url })
        }
    }

    func delete(_ note: Note) {
        if selected?.id == note.id {
            saveWork?.cancel()
            selected = nil
            text = ""
        }
        try? FileManager.default.trashItem(at: note.id, resultingItemURL: nil)
        refresh()
    }

    /// Voice capture: append to a named note (fuzzy match), or create a fresh
    /// titled + dated note per capture. Same title same day appends — a new
    /// topic always gets its own file. Returns the HUD line.
    func append(_ raw: String, title: String?, toNoteNamed target: String?) -> String {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "nothing to note" }

        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let url: URL
        if let target,
           let match = notes.first(where: { $0.name.lowercased().contains(target.lowercased()) }) {
            url = match.id
        } else {
            var clean = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            if clean.isEmpty {
                clean = line.split(separator: " ").prefix(4).joined(separator: " ")
            }
            url = dir.appendingPathComponent("\(clean) \(stamp).md")
            if !FileManager.default.fileExists(atPath: url.path) {
                let time = Date().formatted(date: .omitted, time: .shortened)
                try? "# \(clean)\n\(stamp) \(time)\n\n".write(to: url, atomically: true, encoding: .utf8)
            }
        }

        if selected?.id == url { flushSave() }
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += "- \(line)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
        if selected?.id == url { text = content }
        refresh()
        return "noted → \(url.deletingPathExtension().lastPathComponent)"
    }

    func textChanged() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        guard let sel = selected else { return }
        try? text.write(to: sel.id, atomically: true, encoding: .utf8)
    }

    func organize() {
        guard !organizing else { return }
        flushSave()
        organizing = true
        organizeStatus = "claude organizing…"

        let dirPath = dir.path
        Task.detached { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let prompt = "You are organizing a folder of personal markdown notes. For each .md file: give it a proper # title if missing, append a 'tags:' line with 2-4 lowercase topic tags. Then write INDEX.md grouping all notes by theme, one line each: link + 6-10 word summary. Do not delete or merge files."
            proc.arguments = ["-lc", "cd \(dirPath.shellQuoted) && claude -p \(prompt.shellQuoted) --permission-mode acceptEdits 2>&1 | tail -3"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            var status = "done"
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    status = "failed: \(out.suffix(120))"
                }
            } catch {
                status = "failed: \(error.localizedDescription)"
            }

            let finalStatus = status
            await MainActor.run { [weak self] in
                self?.organizing = false
                self?.organizeStatus = finalStatus
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.organizeStatus = nil }
            }
        }
    }
}

extension String {
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct NotesCardView: View {
    @ObservedObject var store: NotesStore
    @State private var editMode = true
    @State private var titleDraft = ""
    @State private var renamingID: URL?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Button(action: { store.newNote() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.headerText)
                    .keyboardShortcut("n", modifiers: .command)
                    .help("new note (⌘N)")
                    Spacer()
                    Button(action: { store.organize() }) {
                        HStack(spacing: 3) {
                            if store.organizing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles").font(.system(size: 9))
                            }
                            Text("organize").font(Theme.mono(9))
                        }
                        .foregroundStyle(Theme.accent.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.organizing)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 4)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(store.notes) { note in
                            noteRow(note)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(width: 150)

            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let sel = store.selected {
                        TextField("untitled", text: $titleDraft)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .focused($titleFocused)
                            .onSubmit {
                                store.rename(sel, to: titleDraft)
                                titleFocused = false
                            }
                            .help("click to rename")
                    }
                    if let status = store.organizeStatus {
                        Text(status)
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.accent.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 0) {
                        modeButton("read", active: !editMode) { store.flushSave(); editMode = false }
                        modeButton("edit", active: editMode) { editMode = true }
                    }
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if store.selected == nil {
                    Spacer()
                    Text("select or + a note")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.headerText)
                    Spacer()
                } else if editMode {
                    TextEditor(text: $store.text)
                        .font(Theme.mono(12))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 6)
                        .onChange(of: store.text) { store.textChanged() }
                } else {
                    ScrollView {
                        Text(renderedMarkdown)
                            .font(Theme.mono(12))
                            .lineSpacing(3)
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .textSelection(.enabled)
                    }
                }

                if let sel = store.selected {
                    HStack {
                        Text("\(wordCount)w · \(store.text.count)c")
                        Spacer()
                        Text(sel.modified, format: .dateTime.day().month().hour().minute())
                    }
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.headerText.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
            }
            .onChange(of: store.selected?.id) {
                titleDraft = store.selected?.name ?? ""
            }
            .onChange(of: titleFocused) {
                if !titleFocused, let sel = store.selected {
                    store.rename(sel, to: titleDraft)
                    titleDraft = store.selected?.name ?? ""
                }
            }
            .onAppear { titleDraft = store.selected?.name ?? "" }
        }
    }

    private var wordCount: Int {
        store.text.split(whereSeparator: { $0.isWhitespace }).count
    }

    @ViewBuilder
    private func noteRow(_ note: Note) -> some View {
        let isSelected = store.selected?.id == note.id
        if renamingID == note.id {
            TextField("", text: $renameText)
                .textFieldStyle(.plain)
                .font(Theme.mono(11))
                .foregroundStyle(.white.opacity(0.95))
                .focused($renameFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .onAppear { renameFocused = true }
                .onSubmit {
                    store.rename(note, to: renameText)
                    renamingID = nil
                }
                .onExitCommand { renamingID = nil }
                .onChange(of: renameFocused) {
                    if !renameFocused, renamingID == note.id {
                        store.rename(note, to: renameText)
                        renamingID = nil
                    }
                }
        } else {
            Text(note.name)
                .font(Theme.mono(11))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .white.opacity(0.95) : Theme.headerText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Color.white.opacity(0.08) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { store.delete(note) }
                .simultaneousGesture(TapGesture().onEnded { store.select(note) })
                .contextMenu {
                    Button("rename") {
                        renameText = note.name
                        renamingID = note.id
                    }
                    Button("delete", role: .destructive) { store.delete(note) }
                }
                .help("double-click to delete · right-click to rename")
        }
    }

    private var renderedMarkdown: AttributedString {
        (try? AttributedString(
            markdown: store.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(store.text)
    }

    private func modeButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.mono(9, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.black.opacity(0.85) : Theme.headerText)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(active ? Theme.accent : .clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
