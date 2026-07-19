import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: WorkingCopyStore

    enum SortColumn { case name, status, rev }
    @State private var sortColumn: SortColumn = .name
    @State private var sortAscending = true

    // Height of the top (directory) pane, remembered across launches. During a
    // drag we use a transient @State value (dragTop) so we don't write UserDefaults
    // — or refresh the NSBrowser — on every frame (that caused jitter).
    @AppStorage("dirPaneHeight") private var savedTopHeight: Double = 190
    @State private var splitAreaHeight: CGFloat = 0
    @State private var dragStartTop: Double? = nil
    @State private var dragTop: Double? = nil
    @State private var isResizing = false

    private var topHeight: Double { dragTop ?? savedTopHeight }

    /// Files of the current directory, sorted (directories live in the top pane).
    /// Dot-files hidden unless "Show Hidden Files"; non-versioned files hidden
    /// unless "Show Non-CVS Files".
    private var sortedFiles: [DirItem] {
        sortedItems.filter { item in
            guard !item.isDirectory else { return false }
            if !store.showHidden, item.name.hasPrefix(".") { return false }
            if !store.showNonCVS, !item.underCVS { return false }
            return true
        }
    }

    /// Items sorted by the active column. Directories are always grouped first.
    private var sortedItems: [DirItem] {
        store.items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let byName = a.name.localizedStandardCompare(b.name) == .orderedAscending
            var result: Bool
            switch sortColumn {
            case .name:
                result = byName
            case .status:
                result = a.status.sortRank == b.status.sortRank
                    ? byName : a.status.sortRank < b.status.sortRank
            case .rev:
                let c = a.revision.localizedStandardCompare(b.revision)
                result = c == .orderedSame ? byName : (c == .orderedAscending)
            }
            return sortAscending ? result : !result
        }
    }

    private func toggleSort(_ col: SortColumn) {
        if sortColumn == col { sortAscending.toggle() }
        else { sortColumn = col; sortAscending = true }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    directoryPane.frame(height: topHeight)
                    resizerBar
                    filesPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear { splitAreaHeight = geo.size.height; clampTop() }
                .onChange(of: geo.size.height) { _, h in splitAreaHeight = h; clampTop() }
            }
            Divider()
            consolePane
        }
        .frame(minWidth: 760, minHeight: 560)
        .toolbar { toolbarContent }
        .navigationTitle(store.rootName)
        .navigationSubtitle(pathSubtitle)
        .safeAreaInset(edge: .bottom) { statusBar }
        .sheet(isPresented: $store.showCommitSheet) { CommitSheet() }
        .sheet(item: Binding(
            get: { store.logText.map { TextPayload(title: "Log", text: $0) } },
            set: { if $0 == nil { store.logText = nil } })
        ) { payload in TextViewerSheet(title: payload.title, text: payload.text, isDiff: false) }
    }

    private var pathSubtitle: String {
        let loc = store.currentDir.isEmpty ? "" : " › " + store.currentDir
        return store.cvsRootDescription + loc
    }

    // MARK: - Draggable resizer between the two panes

    private var resizerBar: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .separatorColor))
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 44, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 11)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            // Measure in GLOBAL space: the bar itself moves as the pane resizes,
            // so a local-space translation feeds back on itself and oscillates.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartTop == nil { dragStartTop = savedTopHeight; isResizing = true }
                    dragTop = clampedTop((dragStartTop ?? savedTopHeight) + value.translation.height)
                }
                .onEnded { _ in
                    if let d = dragTop { savedTopHeight = d }   // persist once, on release
                    dragTop = nil
                    dragStartTop = nil
                    isResizing = false
                }
        )
    }

    private func clampedTop(_ h: Double) -> Double {
        let maxTop = max(120, Double(splitAreaHeight) - 170)  // keep files pane usable
        return min(max(h, 90), maxTop)
    }

    private func clampTop() {
        guard splitAreaHeight > 0, !isResizing else { return }
        savedTopHeight = clampedTop(savedTopHeight)
    }

    // MARK: - Directory column browser (top pane)

    private var directoryPane: some View {
        Group {
            if store.root != nil || !store.recents.isEmpty {
                DirectoryColumnBrowser(
                    recents: store.recents,
                    activeRoot: store.root,
                    currentDir: store.currentDir,
                    reloadToken: store.browserReloadToken,
                    showHidden: store.showHidden,
                    showNonCVS: store.showNonCVS,
                    suspendUpdates: isResizing,
                    onSelect: { root, dir in store.browserSelect(root: root, dir: dir) },
                    onRemove: { root in store.removeRecent(root) }
                )
            } else {
                Text("Open a CVS working copy to begin (⌘O)")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    // MARK: - Files in the selected directory (bottom pane)

    private var filesPane: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            browser
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("").frame(width: 22)
            sortHeader("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Status", .status).frame(width: 120, alignment: .leading)
            sortHeader("Rev", .rev).frame(width: 70, alignment: .leading)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func sortHeader(_ title: String, _ col: SortColumn) -> some View {
        Button { toggleSort(col) } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortColumn == col {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(sortColumn == col ? Color.primary : Color.secondary)
    }

    private var browser: some View {
        List(selection: $store.selection) {
            ForEach(sortedFiles) { item in
                row(item).tag(item.id)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        // Native List selection only (no row tap gestures — they race with the
        // table's own click handling and make mouse selection flaky). Double-click
        // to open is handled by an AppKit event monitor that only observes clicks;
        // Return opens the selected item; directories also have a chevron button.
        .onKeyPress(.return) { openSelected(); return .handled }
        .onHover { store.pointerOverBrowser = $0 }
        .onAppear { store.installDoubleClickMonitor() }
        .overlay { if store.isBusy && !store.runningCommand.isEmpty { runningOverlay } }
        .contextMenu(forSelectionType: DirItem.ID.self) { _ in
            Button(store.selectedVersionedFiles.count > 1 ? "Diff Selected Files" : "Diff") {
                Task { await store.diffSelected() }
            }
            Button("Log") { Task { await store.log() } }
            Divider()
            Button("Update") { Task { await store.updateSelectedOrCurrentDir() } }
            Button("Add") { Task { await store.add() } }
            Button("Revert (discard local changes)") { Task { await store.revert() } }
            Button("Reveal in Finder") { revealSelection() }
        }
    }

    /// Floating card shown while a cvs command is running, with live progress.
    private var runningOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text(store.runningCommand.isEmpty ? "Working…" : store.runningCommand)
                .font(.callout.monospaced())
                .lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.center)
            if !store.progressLine.isEmpty {
                Text(store.progressLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(20)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
    }

    private func row(_ item: DirItem) -> some View {
        HStack(spacing: 0) {
            Text(item.isDirectory ? "" : item.status.letter)
                .font(.system(.body, design: .monospaced).bold())
                .foregroundStyle(item.status.color)
                .frame(width: 22)
            HStack(spacing: 6) {
                Image(systemName: icon(for: item))
                    .foregroundStyle(item.isDirectory ? .blue : item.status.color)
                Text(item.name)
                    .foregroundStyle(item.isDirectory || item.status == .upToDate
                                     ? .primary : item.status.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.isDirectory ? "" : item.status.label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(item.revision)
                .font(.callout.monospaced()).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
        }
    }

    /// Open whatever single row is selected: directory → enter, file → diff.
    private func openSelected() {
        guard store.selection.count == 1, let item = store.selectedItems.first else { return }
        store.enter(item)
    }

    private func icon(for item: DirItem) -> String {
        if item.isDirectory { return item.underCVS ? "folder.fill" : "folder" }
        switch item.status {
        case .conflict:    return "exclamationmark.triangle.fill"
        case .needsUpdate: return "arrow.down.circle"
        case .added:       return "plus.circle"
        case .removed:     return "minus.circle"
        case .missing:     return "questionmark.circle"
        case .unknown:     return "circle.dotted"
        case .modified:    return "pencil.circle"
        default:           return "doc.text"
        }
    }

    // MARK: - Console

    private var consolePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Console").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { store.clearConsole() }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(store.console.isEmpty ? "cvs output appears here." : store.console)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(store.console.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                }
                .onChange(of: store.console) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(height: 130)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if store.isBusy { ProgressView().controlSize(.small) }
            Text(store.statusLine).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { openWorkingCopy() } label: { Label("Open", systemImage: "folder") }
            Button {
                store.browserReloadToken += 1
                Task { await store.refresh(contactServer: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }.disabled(store.root == nil)

            Divider()

            Button { Task { await store.diffSelected() } } label: {
                Label("Diff", systemImage: "rectangle.split.2x1")
            }.disabled(store.selectedVersionedFiles.isEmpty)
                .help("Diff the selected file(s)")
            Button { Task { await store.updateSelectedOrCurrentDir() } } label: {
                Label("Update", systemImage: "arrow.down.circle")
            }.disabled(store.root == nil)

            // Prominent, clearly-labelled Commit button (always shows its title).
            Button { store.showCommitSheet = true } label: {
                Label("Commit", systemImage: "arrow.up.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.root == nil)
            .help("Commit changed files in this folder")

            // Secondary actions tucked into a menu so the bar never overflows.
            Menu {
                Button("Log") { Task { await store.log() } }
                    .disabled(store.selection.isEmpty)
                Button("Add") { Task { await store.add() } }
                    .disabled(store.selection.isEmpty)
                Button("Revert (discard local changes)") { Task { await store.revert() } }
                    .disabled(store.selectedVersionedFiles.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Actions

    private func openWorkingCopy() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Working Copy"
        if panel.runModal() == .OK, let url = panel.url {
            store.open(url.path)
        }
    }

    private func revealSelection() {
        guard let root = store.root else { return }
        let urls = store.selectedItems.map { URL(fileURLWithPath: root + "/" + $0.relPath) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

/// Payload for identifiable text sheets.
struct TextPayload: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}
