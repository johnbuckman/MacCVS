import SwiftUI
import AppKit

// MARK: - Model

struct LogEntry: Identifiable {
    let id = UUID()
    let revision: String
    let date: String
    let author: String
    let state: String
    let added: Int
    let deleted: Int
    let message: String
}

struct LogFile: Identifiable {
    let id = UUID()
    let path: String                 // relative to working-copy root
    let entries: [LogEntry]           // newest first
}

struct LogPayload: Identifiable {
    let id = UUID()
    let title: String
    let root: String
    let files: [LogFile]
}

// MARK: - Parser for `cvs log`

enum CVSLogParser {
    static func parse(_ output: String) -> [LogFile] {
        var files: [LogFile] = []
        var path: String?
        var entries: [LogEntry] = []
        var pending: [String] = []
        var collecting = false

        func flushEntry() {
            if !pending.isEmpty { if let e = parseEntry(pending) { entries.append(e) }; pending = [] }
        }
        func flushFile() {
            flushEntry()
            if let p = path { files.append(LogFile(path: p, entries: entries)) }
            path = nil; entries = []; collecting = false
        }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("RCS file:") { flushFile() }
            else if line.hasPrefix("Working file: ") { path = String(line.dropFirst("Working file: ".count)) }
            else if line.hasPrefix("----------") { flushEntry(); collecting = true }
            else if line.hasPrefix("==========") { flushEntry(); collecting = false }
            else if collecting { pending.append(line) }
        }
        flushFile()
        return files
    }

    private static func parseEntry(_ lines: [String]) -> LogEntry? {
        var revision = "", date = "", author = "", state = "", added = 0, deleted = 0
        var message: [String] = []
        for line in lines {
            if line.hasPrefix("revision ") {
                revision = String(line.dropFirst("revision ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("date:") {
                for field in line.split(separator: ";") {
                    let f = field.trimmingCharacters(in: .whitespaces)
                    if f.hasPrefix("date: ") { date = String(f.dropFirst(6)) }
                    else if f.hasPrefix("author: ") { author = String(f.dropFirst(8)) }
                    else if f.hasPrefix("state: ") { state = String(f.dropFirst(7)) }
                    else if f.hasPrefix("lines: ") {
                        for tok in String(f.dropFirst(7)).split(separator: " ") {
                            if tok.hasPrefix("+") { added = Int(tok.dropFirst()) ?? 0 }
                            else if tok.hasPrefix("-") { deleted = Int(tok.dropFirst()) ?? 0 }
                        }
                    }
                }
            } else if line.hasPrefix("branches:") {
                continue
            } else {
                message.append(line)
            }
        }
        guard !revision.isEmpty else { return nil }
        return LogEntry(revision: revision, date: date, author: author, state: state,
                        added: added, deleted: deleted,
                        message: message.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Window

@MainActor
final class LogWindowManager: NSObject, NSWindowDelegate {
    static let shared = LogWindowManager()
    private var windows: Set<NSWindow> = []

    func present(_ payload: LogPayload) {
        let hosting = NSHostingController(rootView: LogView(payload: payload))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "History — " + payload.title
        window.setContentSize(NSSize(width: 820, height: 720))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows.insert(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow { windows.remove(w) }
    }
}

// MARK: - View

struct LogView: View {
    let payload: LogPayload
    @State private var showDiffs = false

    private var totalEntries: Int { payload.files.reduce(0) { $0 + $1.entries.count } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(LinearGradient(colors: [Color(hex: "667eea"), Color(hex: "764ba2")],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 1) {
                    Text(payload.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("\(totalEntries) revision(s)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: $showDiffs) {
                    Label("Show diffs", systemImage: "plusminus")
                }
                .toggleStyle(.button)
                .help("Show the visual diff of what changed in each revision")
            }
            .padding(10)
            .background(.bar)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(payload.files) { file in
                        if payload.files.count > 1 {
                            Text(file.path).font(.callout.bold())
                                .padding(.horizontal, 12).padding(.top, 6)
                        }
                        ForEach(Array(file.entries.enumerated()), id: \.element.id) { idx, entry in
                            LogEntryView(
                                root: payload.root,
                                relPath: file.path,
                                entry: entry,
                                previousRevision: idx + 1 < file.entries.count ? file.entries[idx + 1].revision : nil,
                                showDiffs: showDiffs
                            )
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}

private struct LogEntryView: View {
    let root: String
    let relPath: String
    let entry: LogEntry
    let previousRevision: String?
    let showDiffs: Bool

    @State private var diff: [DiffFile]? = nil
    @State private var loading = false
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(entry.revision)
                    .font(.system(.body, design: .monospaced).bold())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                Text(entry.author).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(entry.date).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if entry.added > 0 { Text("+\(entry.added)").font(.callout.monospaced()).foregroundStyle(.green) }
                if entry.deleted > 0 { Text("-\(entry.deleted)").font(.callout.monospaced()).foregroundStyle(.red) }
            }
            if !entry.message.isEmpty {
                Text(entry.message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showDiffs {
                Divider().padding(.vertical, 2)
                if let diff {
                    if diff.isEmpty { Text("(no textual changes)").font(.caption).foregroundStyle(.secondary) }
                    else { InlineDiffView(files: diff) }
                } else if loading {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading diff…").font(.caption).foregroundStyle(.secondary) }
                } else if loadFailed {
                    Text("Couldn’t load diff.").font(.caption).foregroundStyle(.secondary)
                } else if previousRevision == nil {
                    Text("Initial revision — no previous version to compare.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .task(id: showDiffs) { await loadDiffIfNeeded() }
    }

    private func loadDiffIfNeeded() async {
        guard showDiffs, diff == nil, !loading, let prev = previousRevision else { return }
        loading = true; loadFailed = false
        // Diff between the previous revision and this one — what this commit changed.
        let result = await CVSService.run(["diff", "-u", "-r", prev, "-r", entry.revision, relPath], in: root)
        let parsed = CVSDiffParser.parse(result.stdout).map { DiffFile(path: relPath, hunks: $0.hunks) }
        loading = false
        if parsed.isEmpty && result.exitCode > 1 { loadFailed = true }   // exit 1 = diffs exist (fine)
        else { diff = parsed }
    }
}
