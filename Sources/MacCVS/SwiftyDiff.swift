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
            var dels: [DiffLine] = [], adds: [DiffLine] = []
            func flush() {
                for k in 0..<max(dels.count, adds.count) {
                    rows.append(.pair(left: k < dels.count ? dels[k] : nil,
                                      right: k < adds.count ? adds[k] : nil))
                }
                dels.removeAll(); adds.removeAll()
            }
            for line in hunk.lines {
                switch line.type {
                case .context:  flush(); rows.append(.pair(left: line, right: line))
                case .deletion: dels.append(line)
                case .addition: adds.append(line)
                }
            }
            flush()
        }
        return rows
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

    private var totalAdd: Int { payload.files.reduce(0) { $0 + $1.additions } }
    private var totalDel: Int { payload.files.reduce(0) { $0 + $1.deletions } }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            GeometryReader { geo in
                ScrollView(.vertical) {   // shared vertical scroll; panes scroll horizontally themselves
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(payload.files) { file in
                            DiffFileView(file: file, availableWidth: geo.size.width,
                                         unified: unified, wordMode: wordMode,
                                         leftFraction: $leftFraction)
                        }
                    }
                    .frame(minHeight: geo.size.height, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(minWidth: 640, minHeight: 360)
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

    @State private var dragStartFraction: CGFloat? = nil
    private let charW: CGFloat = 7.0
    private let gutter: CGFloat = 46
    private let dividerW: CGFloat = 8
    private let rowH: CGFloat = 18
    private let hunkH: CGFloat = 20
    private let labelH: CGFloat = 22

    private var rows: [DiffRow] { CVSDiffParser.rows(for: file) }
    private enum Side { case left, right }

    /// Exact content height — a horizontal ScrollView is greedy vertically, so we
    /// must pin its height or every row balloons with empty space.
    private var contentHeight: CGFloat {
        var h: CGFloat = 0
        for row in rows { if case .hunk = row { h += hunkH } else { h += rowH } }
        return h
    }

    // Visible pane widths (what the ScrollView shows); content may be wider.
    private var leftVisible: CGFloat { max(120, min(availableWidth - 128, availableWidth * leftFraction)) }
    private var rightVisible: CGFloat { max(80, availableWidth - leftVisible - dividerW) }

    private func contentWidth(_ side: Side) -> CGFloat {
        var maxLen = 0
        for row in rows {
            switch row {
            case .hunk(let h): if side == .left { maxLen = max(maxLen, h.count + 2) }
            case .pair(let l, let r): maxLen = max(maxLen, (side == .left ? l : r)?.content.count ?? 0)
            }
        }
        return CGFloat(maxLen) * charW + gutter + 20
    }
    private func paneWidth(_ side: Side) -> CGFloat {
        max(side == .left ? leftVisible : rightVisible, contentWidth(side))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header (full window width).
            HStack(spacing: 10) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.blue)
                Text(file.path).font(.system(size: 15, weight: .bold))
                Spacer()
                if file.additions > 0 { Text("+\(file.additions)").font(.callout.monospaced()).foregroundStyle(.green) }
                if file.deletions > 0 { Text("-\(file.deletions)").font(.callout.monospaced()).foregroundStyle(.red) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: availableWidth, alignment: .leading)
            .background(Color(nsColor: .underPageBackgroundColor))

            if unified {
                ScrollView(.horizontal) { unifiedBody }.frame(width: availableWidth, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    column(.left).frame(width: leftVisible)
                    divider
                    column(.right).frame(width: rightVisible)
                }
                .frame(width: availableWidth, alignment: .topLeading)
            }
            Divider().frame(width: availableWidth)
        }
    }

    // MARK: side-by-side columns (each scrolls horizontally; vertical is shared)

    private func column(_ side: Side) -> some View {
        VStack(spacing: 0) {
            paneLabel(side == .left ? "BEFORE" : "AFTER", color: side == .left ? .red : .green)
                .frame(width: side == .left ? leftVisible : rightVisible, height: labelH)
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        switch row {
                        case .hunk(let header):
                            Text(side == .left ? header : "")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.blue)
                                .padding(.horizontal, 8)
                                .frame(width: paneWidth(side), height: hunkH, alignment: .leading)
                                .background(Color.blue.opacity(0.08))
                        case .pair(let l, let r):
                            cell(line: side == .left ? l : r, other: side == .left ? r : l, side: side)
                        }
                    }
                }
            }
            .frame(height: contentHeight)   // pin height (horizontal ScrollView is greedy vertically)
        }
    }

    private var divider: some View {
        ZStack { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 2) }
            .frame(width: dividerW, height: labelH + contentHeight)   // definite height → row won't center
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

    private var unifiedBody: some View {
        VStack(spacing: 0) {
            ForEach(file.hunks) { hunk in
                Text(hunk.header).font(.system(size: 11, design: .monospaced)).foregroundStyle(.blue)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .frame(width: unifiedContentWidth, alignment: .leading)
                    .background(Color.blue.opacity(0.08))
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
    }

    private func prefix(_ line: DiffLine) -> String {
        switch line.type { case .addition: return "+ "; case .deletion: return "- "; case .context: return "  " }
    }

    private func paneLabel(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.bold()).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 3).background(color.opacity(0.7))
    }
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
