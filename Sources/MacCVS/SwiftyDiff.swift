import SwiftUI
import AppKit

//
//  In-app visual diff. Model (DiffFile/DiffHunk/DiffLine), side-by-side layout,
//  BEFORE/AFTER panes, +/- stats and gradient accent are adapted from swifty-diff
//  (GitDiffViewer) by Michael Neale, MIT: https://github.com/michaelneale/swifty-diff
//  Extensions beyond swifty-diff: driven by `cvs diff -u`, a real resizable window,
//  a unified-view toggle, and WORD-level (intra-line) highlighting (swifty-diff is
//  line-only).
//

// MARK: - Model

struct DiffFile: Identifiable {
    let id = UUID()
    let path: String
    let hunks: [DiffHunk]
    var additions: Int { hunks.flatMap(\.lines).filter { $0.type == .addition }.count }
    var deletions: Int { hunks.flatMap(\.lines).filter { $0.type == .deletion }.count }
}

struct DiffHunk: Identifiable {
    let id = UUID()
    let header: String
    let lines: [DiffLine]
}

struct DiffLine: Identifiable {
    let id = UUID()
    let type: LineType
    let content: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    enum LineType {
        case context, addition, deletion
        var backgroundColor: Color {
            switch self {
            case .context:  return .clear
            case .addition: return Color.green.opacity(0.15)
            case .deletion: return Color.red.opacity(0.15)
            }
        }
    }
}

enum DiffRow { case hunk(String); case pair(left: DiffLine?, right: DiffLine?) }

struct DiffPayload: Identifiable {
    let id = UUID()
    let title: String
    let files: [DiffFile]
    /// Working-copy root. When set, each hunk shows a "Discard" button and each
    /// file a "Discard all" button that revert the working file to the committed
    /// version. Left nil for compares that aren't backed by a CVS working copy.
    var root: String? = nil
    /// Called after a successful discard with the file's relative path, so the
    /// host can `cvs update` the file (re-stamping its status, pulling any server
    /// changes) before the diff window re-reads it. Runs on the main actor.
    var onDiscarded: ((String) async -> Void)? = nil
}

// MARK: - Parser (adapts swifty-diff's git parser to `cvs diff -u` / `diff -u`)

enum CVSDiffParser {
    static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            if lines[i].hasPrefix("Index: ") {
                let path = String(lines[i].dropFirst("Index: ".count)).trimmingCharacters(in: .whitespaces)
                i += 1
                var hunks: [DiffHunk] = []
                while i < lines.count, !lines[i].hasPrefix("Index: ") {
                    if lines[i].hasPrefix("@@") {
                        let (h, n) = parseHunk(lines, i); if let h { hunks.append(h) }; i = n
                    } else { i += 1 }
                }
                files.append(DiffFile(path: path, hunks: hunks))
            } else { i += 1 }
        }
        if files.isEmpty, text.contains("@@") {
            var hunks: [DiffHunk] = []; var i = 0
            while i < lines.count {
                if lines[i].hasPrefix("@@") { let (h, n) = parseHunk(lines, i); if let h { hunks.append(h) }; i = n }
                else { i += 1 }
            }
            if !hunks.isEmpty { files.append(DiffFile(path: "(diff)", hunks: hunks)) }
        }
        return files
    }

    private static func parseHunk(_ lines: [String], _ start: Int) -> (DiffHunk?, Int) {
        var i = start
        let header = lines[i]
        let pattern = #"@@\s*-([0-9]+),?([0-9]*)\s*\+([0-9]+),?([0-9]*)\s*@@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else {
            return (nil, i + 1)
        }
        let ns = header as NSString
        var oldNum = Int(ns.substring(with: m.range(at: 1))) ?? 0
        var newNum = Int(ns.substring(with: m.range(at: 3))) ?? 0
        i += 1
        var diffLines: [DiffLine] = []
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("@@") || line.hasPrefix("Index: ") { break }
            if line.hasPrefix("\\") { i += 1; continue }
            if line.hasPrefix("+") {
                diffLines.append(DiffLine(type: .addition, content: String(line.dropFirst()),
                                          oldLineNumber: nil, newLineNumber: newNum)); newNum += 1
            } else if line.hasPrefix("-") {
                diffLines.append(DiffLine(type: .deletion, content: String(line.dropFirst()),
                                          oldLineNumber: oldNum, newLineNumber: nil)); oldNum += 1
            } else if line.hasPrefix(" ") || line.isEmpty {
                diffLines.append(DiffLine(type: .context, content: String(line.dropFirst()),
                                          oldLineNumber: oldNum, newLineNumber: newNum)); oldNum += 1; newNum += 1
            } else { break }
            i += 1
        }
        return (DiffHunk(header: header, lines: diffLines), i)
    }

    static func rows(for file: DiffFile) -> [DiffRow] {
        var rows: [DiffRow] = []
        for hunk in file.hunks {
            rows.append(.hunk(hunk.header))
            for pr in pairRows(for: hunk) { rows.append(.pair(left: pr.left, right: pr.right)) }
        }
        return rows
    }

    /// Align one hunk's deletions/additions into BEFORE/AFTER row pairs (the same
    /// pairing `rows(for:)` uses, but for a single hunk so it can render on its own).
    static func pairRows(for hunk: DiffHunk) -> [(left: DiffLine?, right: DiffLine?)] {
        var out: [(left: DiffLine?, right: DiffLine?)] = []
        var dels: [DiffLine] = [], adds: [DiffLine] = []
        func flush() {
            for k in 0..<max(dels.count, adds.count) {
                out.append((left: k < dels.count ? dels[k] : nil,
                            right: k < adds.count ? adds[k] : nil))
            }
            dels.removeAll(); adds.removeAll()
        }
        for line in hunk.lines {
            switch line.type {
            case .context:  flush(); out.append((left: line, right: line))
            case .deletion: dels.append(line)
            case .addition: adds.append(line)
            }
        }
        flush()
        return out
    }
}

// MARK: - Discard (revert a hunk / whole file to the committed version)

/// Reverts working-copy changes at hunk granularity by reverse-applying a
/// reconstructed unified-diff patch with the system `patch` tool. Because the
/// patch is rebuilt from the exact hunk we're showing, it applies cleanly at the
/// right lines and leaves every *other* hunk in the file untouched.
enum HunkDiscard {
    /// Rebuild unified-diff text for the given hunks of one file. The `---`/`+++`
    /// names are cosmetic — `patch` is handed the target file explicitly.
    static func patchText(path: String, hunks: [DiffHunk]) -> String {
        var out = "--- \(path)\n+++ \(path)\n"
        for hunk in hunks {
            out += hunk.header + "\n"
            for line in hunk.lines {
                let prefix: String
                switch line.type {
                case .context:  prefix = " "
                case .addition: prefix = "+"
                case .deletion: prefix = "-"
                }
                out += prefix + line.content + "\n"
            }
        }
        return out
    }

    /// Reverse-apply `hunks` to the working file, restoring the committed content
    /// for just those hunks. Returns nil on success, or an error message.
    static func discard(root: String, path: String, hunks: [DiffHunk]) async -> String? {
        let patchTool = "/usr/bin/patch"
        guard FileManager.default.isExecutableFile(atPath: patchTool) else {
            return "patch tool not found at \(patchTool)"
        }
        let target = root + "/" + path
        let tmp = NSTemporaryDirectory() + "maccvs-discard-\(UUID().uuidString).patch"
        do { try patchText(path: path, hunks: hunks).write(toFile: tmp, atomically: true, encoding: .utf8) }
        catch { return "Could not write patch: \(error.localizedDescription)" }
        defer {
            let fm = FileManager.default
            try? fm.removeItem(atPath: tmp)
            try? fm.removeItem(atPath: target + ".orig")   // some patch builds leave a backup
        }
        let r = await CVSService.runTool(patchTool, ["-R", "-p0", target, tmp], in: root)
        if r.exitCode != 0 {
            try? FileManager.default.removeItem(atPath: target + ".rej")
            let msg = (r.stderr.isEmpty ? r.stdout : r.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? "patch failed (exit \(r.exitCode))" : msg
        }
        return nil
    }
}

// MARK: - Inline (word-level) diff — beyond swifty-diff

struct InlineSeg { let text: String; let changed: Bool }

enum InlineDiff {
    /// Word-level highlight of what changed between two lines, via common
    /// leading/trailing token runs. Returns per-side segments to colour.
    static func segments(_ old: String, _ new: String) -> (left: [InlineSeg], right: [InlineSeg]) {
        let o = tokenize(old), n = tokenize(new)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p, s < n.count - p, o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        func build(_ t: [String]) -> [InlineSeg] {
            let pre = t[0..<p].joined()
            let mid = t[p..<(t.count - s)].joined()
            let suf = t[(t.count - s)...].joined()
            var segs: [InlineSeg] = []
            if !pre.isEmpty { segs.append(InlineSeg(text: pre, changed: false)) }
            if !mid.isEmpty { segs.append(InlineSeg(text: mid, changed: true)) }
            if !suf.isEmpty { segs.append(InlineSeg(text: suf, changed: false)) }
            return segs.isEmpty ? [InlineSeg(text: "", changed: false)] : segs
        }
        return (build(o), build(n))
    }

    private static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        var curIsWord: Bool? = nil
        for ch in s {
            let isW = ch.isLetter || ch.isNumber || ch == "_"
            if curIsWord == nil { curIsWord = isW; cur = String(ch) }
            else if isW == curIsWord { cur.append(ch) }
            else { out.append(cur); cur = String(ch); curIsWord = isW }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func attributed(_ segs: [InlineSeg], changedColor: Color) -> AttributedString {
        var result = AttributedString()
        for seg in segs {
            var a = AttributedString(seg.text)
            if seg.changed { a.backgroundColor = changedColor }
            result.append(a)
        }
        return result
    }
}

// MARK: - Compact inline diff (unified, coloured) — for embedding e.g. in the log

struct InlineDiffView: View {
    let files: [DiffFile]
    private let charW: CGFloat = 6.8

    private func width(_ file: DiffFile) -> CGFloat {
        let maxLen = file.hunks.flatMap(\.lines).map { $0.content.count + 2 }.max() ?? 0
        return max(200, CGFloat(maxLen) * charW + 70)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files) { file in
                    ForEach(file.hunks) { hunk in
                        Text(hunk.header)
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.blue)
                            .padding(.horizontal, 6).frame(width: width(file), height: 15, alignment: .leading)
                            .background(Color.blue.opacity(0.08))
                        ForEach(hunk.lines) { line in
                            Text(prefix(line) + line.content)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 6)
                                .frame(width: width(file), height: 15, alignment: .leading)
                                .background(line.type.backgroundColor)
                        }
                    }
                }
            }
        }
    }

    private func prefix(_ line: DiffLine) -> String {
        switch line.type { case .addition: return "+ "; case .deletion: return "- "; case .context: return "  " }
    }
}

// MARK: - Diff window

@MainActor
final class DiffWindowManager: NSObject, NSWindowDelegate {
    static let shared = DiffWindowManager()
    private var windows: Set<NSWindow> = []

    func present(_ payload: DiffPayload) {
        let hosting = NSHostingController(rootView: DiffView(payload: payload))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = payload.title
        window.setContentSize(desiredSize(for: payload))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows.insert(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open wide enough to fit the widest diff line (both panes fully visible),
    /// capped to the screen — so wide diffs don't force horizontal scrolling.
    private func desiredSize(for payload: DiffPayload) -> NSSize {
        let charW: CGFloat = 7.0, gutter: CGFloat = 46, dividerW: CGFloat = 8
        var contentW: CGFloat = 700
        var rowCount = 0
        for file in payload.files {
            let rows = CVSDiffParser.rows(for: file)
            rowCount += rows.count
            var leftLen = 0, rightLen = 0
            for row in rows {
                switch row {
                case .hunk(let h): leftLen = max(leftLen, h.count)
                case .pair(let l, let r):
                    leftLen = max(leftLen, l?.content.count ?? 0)
                    rightLen = max(rightLen, r?.content.count ?? 0)
                }
            }
            let total = CGFloat(leftLen + rightLen) * charW + gutter * 2 + dividerW + 32
            contentW = max(contentW, total)
        }
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = min(contentW, visible.width * 0.96)
        let height = min(max(460, CGFloat(rowCount) * 18 + 220), visible.height * 0.9)
        return NSSize(width: width, height: height)
    }

    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow { windows.remove(w) }
        // In a --diff/--compare launch, quit once the last diff window closes.
        if LaunchMode.isDiffOnly && windows.isEmpty { NSApp.terminate(nil) }
    }
}

// MARK: - Diff view (header bar + toggles + rendering)

struct DiffView: View {
    let payload: DiffPayload
    @AppStorage("diffUnified") private var unified = false
    @AppStorage("diffWordMode") private var wordMode = false
    @State private var leftFraction: CGFloat = 0.5   // draggable split of the two panes

    // Live copy of the diff — mutated as hunks/files are discarded.
    @State private var files: [DiffFile]
    @State private var busy = false
    @State private var errorText: String? = nil
    @State private var window: NSWindow? = nil

    init(payload: DiffPayload) {
        self.payload = payload
        _files = State(initialValue: payload.files)
    }

    private var totalAdd: Int { files.reduce(0) { $0 + $1.additions } }
    private var totalDel: Int { files.reduce(0) { $0 + $1.deletions } }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            GeometryReader { geo in
                ScrollView(.vertical) {   // shared vertical scroll; panes scroll horizontally themselves
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            DiffFileView(file: file, availableWidth: geo.size.width,
                                         unified: unified, wordMode: wordMode,
                                         leftFraction: $leftFraction,
                                         canDiscard: payload.root != nil,
                                         discardAll: { discard(file: file, hunks: file.hunks) },
                                         discardHunk: { discard(file: file, hunks: [$0]) })
                        }
                        if files.isEmpty {
                            Text("All changes discarded — no differences remain.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(40)
                        }
                    }
                    .frame(minHeight: geo.size.height, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .disabled(busy)
        .background(WindowAccessor { window = $0 })
        .alert("Couldn’t discard", isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    /// Reverse-apply `hunks` to `file`, then re-diff the file and update the view.
    /// An emptied window closes itself.
    private func discard(file: DiffFile, hunks: [DiffHunk]) {
        guard let root = payload.root else { return }
        busy = true
        Task {
            if let err = await HunkDiscard.discard(root: root, path: file.path, hunks: hunks) {
                busy = false
                errorText = err
                return
            }
            // Let the host `cvs update` the file (re-stamp status / pull changes)
            // before we re-read it.
            await payload.onDiscarded?(file.path)
            // Re-diff just this file to pick up the shifted line numbers.
            let r = await CVSService.run(["diff", "-u", file.path], in: root)
            let fresh = CVSDiffParser.parse(r.stdout)
                .map { DiffFile(path: file.path, hunks: $0.hunks) }
                .first { !$0.hunks.isEmpty }
            if let idx = files.firstIndex(where: { $0.id == file.id }) {
                if let fresh { files[idx] = fresh } else { files.remove(at: idx) }
            }
            busy = false
            if files.isEmpty { window?.close() }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(LinearGradient(colors: [Color(hex: "667eea"), Color(hex: "764ba2")],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.title).font(.headline).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if totalAdd > 0 { Text("+\(totalAdd)").foregroundStyle(.green) }
                    if totalDel > 0 { Text("-\(totalDel)").foregroundStyle(.red) }
                }.font(.caption.monospaced())
            }
            Spacer()
            Picker("", selection: $unified) {
                Text("Side by side").tag(false); Text("Unified").tag(true)
            }.pickerStyle(.segmented).fixedSize()
            Picker("", selection: $wordMode) {
                Text("Line").tag(false); Text("Word").tag(true)
            }.pickerStyle(.segmented).fixedSize().disabled(unified)
                .help("Highlight whole changed lines, or only the changed words")
        }
        .padding(10)
        .background(.bar)
    }
}

private struct DiffFileView: View {
    let file: DiffFile
    let availableWidth: CGFloat
    let unified: Bool
    let wordMode: Bool
    @Binding var leftFraction: CGFloat
    let canDiscard: Bool
    let discardAll: () -> Void
    let discardHunk: (DiffHunk) -> Void

    @State private var dragStartFraction: CGFloat? = nil
    private let charW: CGFloat = 7.0
    private let gutter: CGFloat = 46
    private let dividerW: CGFloat = 8
    private let rowH: CGFloat = 18
    private let labelH: CGFloat = 22

    private enum Side { case left, right }

    // Visible pane widths (what the ScrollView shows); content may be wider.
    private var leftVisible: CGFloat { max(120, min(availableWidth - 128, availableWidth * leftFraction)) }
    private var rightVisible: CGFloat { max(80, availableWidth - leftVisible - dividerW) }

    // Content width is measured across the whole file so every hunk's columns
    // line up, even though each hunk scrolls horizontally on its own.
    private func contentWidth(_ side: Side) -> CGFloat {
        var maxLen = 0
        for line in file.hunks.flatMap(\.lines) { maxLen = max(maxLen, line.content.count) }
        if side == .left {
            for hunk in file.hunks { maxLen = max(maxLen, hunk.header.count + 2) }
        }
        return CGFloat(maxLen) * charW + gutter + 20
    }
    private func paneWidth(_ side: Side) -> CGFloat {
        max(side == .left ? leftVisible : rightVisible, contentWidth(side))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader
            if !unified { paneLabels }
            ForEach(file.hunks) { hunk in
                hunkHeader(hunk)
                if unified {
                    ScrollView(.horizontal) { unifiedHunk(hunk) }
                        .frame(width: availableWidth, alignment: .leading)
                } else {
                    sideBySideHunk(hunk)
                }
            }
            Divider().frame(width: availableWidth)
        }
    }

    // File header (full window width) with a "Discard all" button.
    private var fileHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.circle.fill").foregroundStyle(.blue)
            Text(file.path).font(.system(size: 15, weight: .bold))
            Spacer()
            if file.additions > 0 { Text("+\(file.additions)").font(.callout.monospaced()).foregroundStyle(.green) }
            if file.deletions > 0 { Text("-\(file.deletions)").font(.callout.monospaced()).foregroundStyle(.red) }
            if canDiscard {
                Button(role: .destructive, action: discardAll) {
                    Label("Discard all", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.small)
                .help("Revert the whole file to the committed version")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: availableWidth, alignment: .leading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // BEFORE / AFTER labels — once per file, above all hunks.
    private var paneLabels: some View {
        HStack(alignment: .top, spacing: 0) {
            paneLabel("BEFORE", color: .red).frame(width: leftVisible, height: labelH)
            Color.clear.frame(width: dividerW, height: labelH)
            paneLabel("AFTER", color: .green).frame(width: rightVisible, height: labelH)
        }
        .frame(width: availableWidth, alignment: .leading)
    }

    // A full-width hunk header bar: @@ … @@ on the left, "Discard" on the right.
    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        HStack(spacing: 8) {
            Text(hunk.header)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.blue)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            if canDiscard {
                Button { discardHunk(hunk) } label: {
                    Label("Discard", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .help("Revert this hunk to the committed version")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(width: availableWidth, alignment: .leading)
        .background(Color.blue.opacity(0.08))
    }

    // MARK: side-by-side columns (each scrolls horizontally; vertical is shared)

    @ViewBuilder
    private func sideBySideHunk(_ hunk: DiffHunk) -> some View {
        let pairs = CVSDiffParser.pairRows(for: hunk)
        let height = CGFloat(pairs.count) * rowH
        HStack(alignment: .top, spacing: 0) {
            column(.left, pairs, height: height).frame(width: leftVisible)
            divider(height: height)
            column(.right, pairs, height: height).frame(width: rightVisible)
        }
        .frame(width: availableWidth, alignment: .topLeading)
    }

    private func column(_ side: Side, _ pairs: [(left: DiffLine?, right: DiffLine?)],
                        height: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pr in
                    cell(line: side == .left ? pr.left : pr.right,
                         other: side == .left ? pr.right : pr.left, side: side)
                }
            }
        }
        .frame(height: height)   // pin height (horizontal ScrollView is greedy vertically)
    }

    private func divider(height: CGFloat) -> some View {
        ZStack { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 2) }
            .frame(width: dividerW, height: height)   // definite height → row won't center
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeLeftRight.set() : NSCursor.arrow.set() }
            .gesture(                       // GLOBAL space: the divider moves as it drags
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if dragStartFraction == nil { dragStartFraction = leftFraction }
                        let delta = v.translation.width / max(availableWidth, 1)
                        leftFraction = min(0.85, max(0.15, (dragStartFraction ?? leftFraction) + delta))
                    }
                    .onEnded { _ in dragStartFraction = nil }
            )
    }

    @ViewBuilder
    private func cell(line: DiffLine?, other: DiffLine?, side: Side) -> some View {
        let number = side == .left ? line?.oldLineNumber : line?.newLineNumber
        let isChange = line?.type == .addition || line?.type == .deletion
        let useWords = wordMode && isChange && line != nil && other != nil
            && (other?.type == .addition || other?.type == .deletion)

        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: gutter, alignment: .trailing).padding(.trailing, 6)
            Group {
                if useWords, let line, let other {
                    let old = side == .left ? line.content : other.content
                    let new = side == .left ? other.content : line.content
                    let segs = InlineDiff.segments(old, new)
                    let mine = side == .left ? segs.left : segs.right
                    let color = side == .left ? Color.red.opacity(0.38) : Color.green.opacity(0.38)
                    Text(InlineDiff.attributed(mine, changedColor: color))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(line?.content ?? "")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: paneWidth(side), height: rowH, alignment: .leading)
        .background(useWords ? Color.clear : (line?.type.backgroundColor ?? Color.gray.opacity(0.06)))
    }

    // MARK: unified

    private var unifiedContentWidth: CGFloat {
        let maxLen = file.hunks.flatMap(\.lines).map { $0.content.count }.max() ?? 0
        return max(availableWidth, CGFloat(maxLen) * charW + 100)
    }

    private func unifiedHunk(_ hunk: DiffHunk) -> some View {
        VStack(spacing: 0) {
            ForEach(hunk.lines) { line in
                HStack(spacing: 0) {
                    Text(line.oldLineNumber.map(String.init) ?? "")
                        .frame(width: 42, alignment: .trailing).padding(.trailing, 4)
                    Text(line.newLineNumber.map(String.init) ?? "")
                        .frame(width: 42, alignment: .trailing).padding(.trailing, 6)
                    Text(prefix(line) + line.content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary)
                .frame(width: unifiedContentWidth, height: rowH, alignment: .leading)
                .background(line.type.backgroundColor)
            }
        }
    }

    private func prefix(_ line: DiffLine) -> String {
        switch line.type { case .addition: return "+ "; case .deletion: return "- "; case .context: return "  " }
    }

    private func paneLabel(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.bold()).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 3).background(color.opacity(0.7))
    }
}

// MARK: - Window accessor (so the diff view can close its own window when empty)

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in if let w = v?.window { onResolve(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Color(hex:) from swifty-diff

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
