import SwiftUI
import Foundation
import AppKit

@MainActor
final class WorkingCopyStore: ObservableObject {
    @Published var root: String? = nil {
        didSet {
            if let root { UserDefaults.standard.set(root, forKey: lastRootKey) }
        }
    }
    @Published var currentDir: String = "" {    // relative to root; "" == root
        didSet { UserDefaults.standard.set(currentDir, forKey: lastDirKey) }
    }
    @Published var items: [DirItem] = []
    @Published var selection: Set<String> = []
    @Published var console: String = ""
    @Published var isBusy = false
    @Published var runningCommand: String = ""   // command currently executing
    @Published var progressLine: String = ""     // latest line of live output
    @Published var statusLine: String = "No working copy open"
    @Published var recents: [String] = []
    @Published var cvsRootDescription: String = ""
    @Published var browserReloadToken = 0   // bump to reload the directory columns
    @Published var showHidden: Bool = UserDefaults.standard.bool(forKey: "showHiddenFiles") {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "showHiddenFiles")
            browserReloadToken += 1   // re-filter the directory columns
        }
    }
    @Published var showNonCVS: Bool = UserDefaults.standard.bool(forKey: "showNonCVSFiles") {
        didSet {
            UserDefaults.standard.set(showNonCVS, forKey: "showNonCVSFiles")
            browserReloadToken += 1   // re-filter the directory columns
        }
    }

    // Presentation state driven from menus/toolbar.
    @Published var logText: String? = nil
    @Published var showCommitSheet = false

    private let recentsKey = "recentWorkingCopies"
    private let lastRootKey = "lastWorkingCopy"
    private let lastDirKey = "lastCurrentDir"

    init() {
        recents = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        if CVSService.locateBinary() == nil {
            statusLine = "⚠︎ bundled cvs not found"
        }
        switch LaunchMode.current {
        case .openDir(let dir):
            if FileManager.default.fileExists(atPath: dir + "/CVS") { open(dir) }
            else { statusLine = "Not a CVS working copy: \(dir)"; restoreLastSession() }
        case .diff:
            break                       // diff-only launch: no main working copy
        case .normal:
            restoreLastSession()
        }
    }

    /// Reopen the working copy and sub-directory that were open last time.
    private func restoreLastSession() {
        let fm = FileManager.default
        guard let last = UserDefaults.standard.string(forKey: lastRootKey),
              fm.fileExists(atPath: last + "/CVS") else { return }
        // Fall back to the root if the remembered sub-directory no longer exists.
        let savedDir = UserDefaults.standard.string(forKey: lastDirKey) ?? ""
        let absDir = savedDir.isEmpty ? last : last + "/" + savedDir
        let dir = fm.fileExists(atPath: absDir) ? savedDir : ""

        ensureRecent(last)
        root = last
        cvsRootDescription = readRootDescription(last)
        currentDir = dir
        selection = []
        Task { await refresh(contactServer: true) }
    }

    private func readRootDescription(_ path: String) -> String {
        (try? String(contentsOfFile: path + "/CVS/Root", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Selection helpers

    var selectedItems: [DirItem] { items.filter { selection.contains($0.id) } }
    var selectedVersionedFiles: [DirItem] { selectedItems.filter { $0.isVersionedFile } }

    /// The single file selected, if exactly one file (not directory) is selected.
    var singleSelectedFile: DirItem? {
        let files = selectedItems.filter { !$0.isDirectory }
        return files.count == 1 ? files.first : nil
    }

    /// Breadcrumb components: [("root", ""), ("sub", "sub"), ("sub/deep", "sub/deep")].
    var breadcrumbs: [(name: String, rel: String)] {
        var crumbs: [(String, String)] = [(rootName, "")]
        guard !currentDir.isEmpty else { return crumbs }
        var acc = ""
        for part in currentDir.split(separator: "/") {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            crumbs.append((String(part), acc))
        }
        return crumbs
    }

    var rootName: String { root.map { ($0 as NSString).lastPathComponent } ?? "MacCVS" }

    // MARK: - Opening / navigation

    func open(_ path: String) {
        guard FileManager.default.fileExists(atPath: path + "/CVS") else {
            appendConsole("Not a CVS working copy (no CVS/ directory): \(path)\n")
            statusLine = "Not a CVS working copy"
            return
        }
        addRecent(path)          // newly opened copy goes to the front of the list
        root = path
        currentDir = ""
        cvsRootDescription = readRootDescription(path)
        selection = []
        Task { await refresh(contactServer: true) }
    }

    /// Selection made in the directory column browser: (root working copy, sub-dir).
    /// Switches the active working copy if a different project's root/row was chosen.
    func browserSelect(root newRoot: String, dir: String) {
        if root != newRoot {
            ensureRecent(newRoot)
            root = newRoot
            cvsRootDescription = readRootDescription(newRoot)
        }
        currentDir = dir
        selection = []
        Task { await refresh(contactServer: true) }
    }

    func navigate(to rel: String) {
        currentDir = rel
        selection = []
        Task { await refresh(contactServer: true) }
    }

    func enter(_ item: DirItem) {
        if item.isDirectory { navigate(to: item.relPath) }
        else { Task { await diff(item) } }   // double-clicking a file diffs it
    }

    // MARK: - Double-click (AppKit event monitor, no selection interference)

    /// True while the pointer is over the file browser (set from ContentView).
    var pointerOverBrowser = false
    private var doubleClickMonitor: Any?

    /// Observe double left-clicks app-wide and, when they land on the browser
    /// with a single row selected, open that row. Because a double-click's first
    /// click already selected the row natively, we only *read* the selection —
    /// we never consume the click, so single-click selection stays pristine.
    func installDoubleClickMonitor() {
        guard doubleClickMonitor == nil else { return }
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                if event.clickCount == 2, self.pointerOverBrowser,
                   self.selection.count == 1, let item = self.selectedItems.first {
                    self.enter(item)
                }
            }
            return event
        }
    }

    func goUp() {
        guard !currentDir.isEmpty else { return }
        navigate(to: (currentDir as NSString).deletingLastPathComponent)
    }

    /// Move a working copy to the front of the recents list (explicit open).
    private func addRecent(_ path: String) {
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > 15 { recents = Array(recents.prefix(15)) }
        UserDefaults.standard.set(recents, forKey: recentsKey)
    }

    /// Ensure a path is present in recents without reordering (switching projects).
    private func ensureRecent(_ path: String) {
        guard !recents.contains(path) else { return }
        recents.append(path)
        UserDefaults.standard.set(recents, forKey: recentsKey)
    }

    /// Remove a stale/duplicate entry from the recents list.
    func removeRecent(_ path: String) {
        recents.removeAll { $0 == path }
        UserDefaults.standard.set(recents, forKey: recentsKey)
    }

    // MARK: - Operations

    func refresh(contactServer: Bool) async {
        guard let root else { return }
        isBusy = true
        statusLine = contactServer ? "Reading \(currentDir.isEmpty ? "/" : currentDir) (contacting server)…"
                                   : "Reading directory…"
        let (listed, log) = await CVSService.listDirectory(root: root, relDir: currentDir,
                                                           contactServer: contactServer)
        items = listed
        if let log, log.exitCode != 0, !log.stderr.isEmpty {
            appendConsole("$ \(log.command)\n\(log.stderr)\n")
        }
        let changed = listed.filter { $0.status.isCommittable }.count
        let dirs = listed.filter { $0.isDirectory }.count
        statusLine = "\(dirs) dirs · \(listed.count - dirs) files · \(changed) changed"
        isBusy = false

        startWatchingCurrentDir()
        for it in items where it.status == .modified { prefetchBase(it) }
    }

    // MARK: - Live change watching + base prefetch (fast diffs)

    /// Cached base-revision temp file per path, so diffs skip the network.
    private var baseCache: [String: (rev: String, path: String)] = [:]

    private lazy var watcher = DirectoryWatcher { [weak self] in
        Task { @MainActor in self?.localRescan() }
    }

    private func startWatchingCurrentDir() {
        guard let root else { return }
        watcher.watch(currentDir.isEmpty ? root : root + "/" + currentDir)
    }

    /// Fast, network-free re-check of the current directory's files: flips files
    /// to Modified (or back) by comparing mtime to the CVS/Entries timestamp, and
    /// prefetches the base revision of anything newly modified.
    func localRescan() {
        guard let root else { return }
        let mods = CVSService.localModifiedStatus(root: root, relDir: currentDir)
        var changed = false
        for idx in items.indices {
            let it = items[idx]
            guard !it.isDirectory, it.underCVS, let isMod = mods[it.name] else { continue }
            if isMod {
                if it.status != .modified, it.status != .conflict, it.status != .needsMerge {
                    items[idx].status = .modified
                    changed = true
                }
                prefetchBase(items[idx])
            } else if it.status == .modified {
                items[idx].status = .upToDate
                baseCache[it.relPath] = nil
                changed = true
            }
        }
        if changed {
            let ch = items.filter { $0.status.isCommittable }.count
            let dirs = items.filter { $0.isDirectory }.count
            statusLine = "Local change detected · \(items.count - dirs) files · \(ch) changed"
        }
    }

    /// Fetch a file's base revision in the background (once per rev) so a later
    /// diff is instant. No-op if already cached for the current revision.
    private func prefetchBase(_ file: DirItem) {
        guard let root, file.underCVS, !file.revision.isEmpty,
              file.revision != "0", !file.revision.hasPrefix("-") else { return }
        if let e = baseCache[file.relPath], e.rev == file.revision { return }
        let rev = file.revision, relPath = file.relPath
        Task {
            if let path = await CVSService.writeBaseRevision(root: root, relPath: relPath, revision: rev) {
                baseCache[relPath] = (rev: rev, path: path)
            }
        }
    }

    /// Run a cvs subcommand (paths relative to root) from the working-copy root,
    /// streaming its output live to the console and progress line.
    private func perform(_ args: [String], on paths: [String], title: String) async {
        guard let root else { return }
        beginRunning(title, command: "cvs " + (args + paths).joined(separator: " "))
        appendConsole("$ cvs \((args + paths).joined(separator: " "))\n")

        let result = await CVSService.runStreaming(args + paths, in: root) { chunk in
            Task { @MainActor in self.appendLive(chunk) }
        }
        if result.exitCode != 0 {
            appendConsole("(exit \(result.exitCode))\n")
        }
        endRunning()
        await refresh(contactServer: true)
    }

    // MARK: - Running / progress state

    private func beginRunning(_ title: String, command: String) {
        isBusy = true
        runningCommand = command
        progressLine = ""
        statusLine = "\(title)…"
    }

    private func endRunning() {
        isBusy = false
        runningCommand = ""
        progressLine = ""
    }

    /// Append a live chunk of command output and surface its last line as progress.
    func appendLive(_ chunk: String) {
        appendConsole(chunk)
        let lines = chunk.split(whereSeparator: \.isNewline)
        if let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            progressLine = String(last)
        }
    }

    func updateSelectedOrCurrentDir() async {
        let paths = selectedItems.map(\.relPath)
        if paths.isEmpty {
            // Update just the current directory (non-recursive) rather than the whole tree.
            let target = currentDir.isEmpty ? ["."] : [currentDir]
            await perform(["update", "-l", "-d", "-P"], on: target, title: "Update directory")
        } else {
            await perform(["update", "-d", "-P"], on: paths, title: "Update")
        }
    }

    func commit(message: String, paths: [String]) async {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await perform(["commit", "-m", message], on: paths, title: "Commit")
    }

    func add() async {
        let paths = selectedItems.map(\.relPath)
        guard !paths.isEmpty else { return }
        await perform(["add"], on: paths, title: "Add")
    }

    func revert() async {
        // cvs has no "revert"; `update -C` overwrites local changes with the repo copy.
        let paths = selectedVersionedFiles.map(\.relPath)
        guard !paths.isEmpty else { return }
        await perform(["update", "-C"], on: paths, title: "Revert")
    }

    /// In-app visual side-by-side diff of one file. Uses the prefetched base
    /// revision + local `diff` when available (instant); otherwise `cvs diff -u`.
    func diff(_ item: DirItem? = nil) async {
        guard let root else { return }
        guard let file = item ?? singleSelectedFile, !file.isDirectory else {
            statusLine = "Select a single file to diff"
            return
        }

        // Fast path: prefetched base + local diff — no network round-trip.
        if let entry = baseCache[file.relPath], entry.rev == file.revision,
           FileManager.default.fileExists(atPath: entry.path) {
            let working = root + "/" + file.relPath
            appendConsole("$ diff -u  (cached base r\(file.revision))  \(file.relPath)  ⚡\n")
            let result = await CVSService.runTool("/usr/bin/diff", ["-u", entry.path, working], in: root)
            let parsed = CVSDiffParser.parse(result.stdout).map { DiffFile(path: file.relPath, hunks: $0.hunks) }
            if parsed.isEmpty || parsed.allSatisfy({ $0.hunks.isEmpty }) {
                statusLine = "No differences in \(file.name)"
            } else {
                DiffWindowManager.shared.present(DiffPayload(title: file.relPath, files: parsed))
                statusLine = "Diff opened (instant)"
            }
            return
        }

        beginRunning("Diffing", command: "cvs diff -u \(file.relPath)")
        appendConsole("$ cvs diff -u \(file.relPath)\n")
        // cvs diff returns exit 1 when there ARE differences — not an error.
        let result = await CVSService.run(["diff", "-u", file.relPath], in: root)
        endRunning()

        let files = CVSDiffParser.parse(result.stdout)
        if files.isEmpty || files.allSatisfy({ $0.hunks.isEmpty }) {
            let why = result.combined.lowercased().contains("no comparison")
                ? "new/unversioned file" : "no differences"
            appendConsole("(\(why))\n")
            statusLine = "No differences in \(file.name)"
            return
        }
        DiffWindowManager.shared.present(DiffPayload(title: file.relPath, files: files))
        statusLine = "Diff opened"
    }

    /// Diff every selected versioned file, shown together in one diff window.
    /// Files whose base revision is already prefetched diff locally (instant, no
    /// network); only the rest hit the network, batched into a single call.
    func diffSelected() async {
        let files = selectedVersionedFiles
        if files.count <= 1 { await diff(files.first); return }
        guard let root else { return }

        var diffFiles: [DiffFile] = []
        var uncached: [DirItem] = []

        // Cached files → local `diff` (no network).
        for file in files {
            if let entry = baseCache[file.relPath], entry.rev == file.revision,
               FileManager.default.fileExists(atPath: entry.path) {
                let working = root + "/" + file.relPath
                let result = await CVSService.runTool("/usr/bin/diff", ["-u", entry.path, working], in: root)
                diffFiles += CVSDiffParser.parse(result.stdout)
                    .map { DiffFile(path: file.relPath, hunks: $0.hunks) }
                    .filter { !$0.hunks.isEmpty }
            } else {
                uncached.append(file)
            }
        }

        // Anything not cached → one batched `cvs diff -u`.
        if !uncached.isEmpty {
            let paths = uncached.map(\.relPath)
            beginRunning("Diffing \(paths.count) file(s)", command: "cvs diff -u " + paths.joined(separator: " "))
            appendConsole("$ cvs diff -u \(paths.joined(separator: " "))\n")
            let result = await CVSService.run(["diff", "-u"] + paths, in: root)
            endRunning()
            diffFiles += CVSDiffParser.parse(result.stdout).filter { !$0.hunks.isEmpty }
        } else {
            appendConsole("$ diff -u  (cached bases)  \(files.count) files  ⚡\n")
        }

        if diffFiles.isEmpty {
            appendConsole("(no differences)\n")
            statusLine = "No differences in selection"
            return
        }
        // Keep the diffs in the selection's on-screen order.
        let order = Dictionary(files.enumerated().map { ($1.relPath, $0) }, uniquingKeysWith: { a, _ in a })
        diffFiles.sort { (order[$0.path] ?? 0) < (order[$1.path] ?? 0) }

        let instant = uncached.isEmpty ? "  ·  instant" : ""
        DiffWindowManager.shared.present(
            DiffPayload(title: "\(diffFiles.count) files\(instant)", files: diffFiles))
        statusLine = "Diff opened (\(diffFiles.count) files)"
    }

    func log() async {
        guard let root else { return }
        let paths = selectedItems.filter { !$0.isDirectory }.map(\.relPath)
        guard !paths.isEmpty else { statusLine = "Select a file to view log"; return }
        beginRunning("Fetching log", command: "cvs log " + paths.joined(separator: " "))
        appendConsole("$ cvs log \(paths.joined(separator: " "))\n")
        let result = await CVSService.run(["log"] + paths, in: root)
        endRunning()

        let files = CVSLogParser.parse(result.stdout)
        if files.isEmpty || files.allSatisfy({ $0.entries.isEmpty }) {
            // Fall back to the raw text viewer if parsing produced nothing.
            logText = result.combined.isEmpty ? "(no log)" : result.combined
            statusLine = "Log ready"
            return
        }
        LogWindowManager.shared.present(
            LogPayload(title: paths.count == 1 ? paths[0] : "\(paths.count) files",
                       root: root, files: files))
        statusLine = "Log opened"
    }

    func appendConsole(_ text: String) {
        console += text
        if console.count > 200_000 { console = String(console.suffix(150_000)) }
    }

    func clearConsole() { console = "" }
}
