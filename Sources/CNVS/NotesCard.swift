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

            await MainActor.run { [weak self] in
                self?.organizing = false
                self?.organizeStatus = status
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
                            Button(action: { store.select(note) }) {
                                Text(note.name)
                                    .font(Theme.mono(11))
                                    .lineLimit(1)
                                    .foregroundStyle(
                                        store.selected?.id == note.id
                                            ? .white.opacity(0.95) : Theme.headerText
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        store.selected?.id == note.id
                                            ? Color.white.opacity(0.08) : .clear
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(width: 150)

            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)

            VStack(spacing: 0) {
                HStack {
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
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 6)
                        .onChange(of: store.text) { store.textChanged() }
                } else {
                    ScrollView {
                        Text(renderedMarkdown)
                            .font(Theme.mono(12))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .textSelection(.enabled)
                    }
                }
            }
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
