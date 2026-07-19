import SwiftUI
import AppKit

/// A node in the column browser. Column 0 holds working-copy roots (the recents
/// list); deeper columns hold sub-directories of the active working copy.
final class BrowserNode: NSObject {
    let rootPath: String       // absolute path of the owning working copy
    let relPath: String        // path relative to rootPath ("" == the root itself)
    let name: String           // display name
    let isWorkingCopy: Bool     // true for column-0 root entries

    init(rootPath: String, relPath: String, name: String, isWorkingCopy: Bool) {
        self.rootPath = rootPath
        self.relPath = relPath
        self.name = name
        self.isWorkingCopy = isWorkingCopy
    }

    var absPath: String { relPath.isEmpty ? rootPath : rootPath + "/" + relPath }
}

/// Finder-style column browser. The first column lists recent CVS working copies
/// (a project switcher); selecting one opens its directory hierarchy in the
/// following columns. `onSelect(rootPath, relPath)` reports the chosen location.
struct DirectoryColumnBrowser: NSViewRepresentable {
    let recents: [String]
    let activeRoot: String?
    let currentDir: String
    let reloadToken: Int
    let showHidden: Bool
    let showNonCVS: Bool
    var suspendUpdates: Bool = false   // true while the pane divider is being dragged
    let onSelect: (_ rootPath: String, _ relPath: String) -> Void
    let onRemove: (_ rootPath: String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(recents: recents, onSelect: onSelect, onRemove: onRemove)
    }

    func makeNSView(context: Context) -> NSBrowser {
        let browser = NSBrowser()
        browser.delegate = context.coordinator
        browser.target = context.coordinator
        browser.action = #selector(Coordinator.browserClicked(_:))
        browser.isTitled = false
        browser.allowsMultipleSelection = false
        browser.allowsEmptySelection = false
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.takesTitleFromPreviousColumn = false

        // Fixed (user-resizable) columns, each 50% wider than the standard default.
        browser.columnResizingType = .userColumnResizing
        let current = browser.defaultColumnWidth()
        let base = current > 1 ? current : 180
        browser.setDefaultColumnWidth(base * 1.5)

        context.coordinator.browser = browser
        context.coordinator.installRightClickMonitor()
        return browser
    }

    func updateNSView(_ browser: NSBrowser, context: Context) {
        // While the divider is being dragged, don't touch the browser at all —
        // reloading/re-selecting each frame makes the columns jitter.
        if suspendUpdates { return }
        let coord = context.coordinator
        coord.recents = recents
        coord.onSelect = onSelect
        coord.onRemove = onRemove
        coord.showHidden = showHidden
        coord.showNonCVS = showNonCVS

        let valid = coord.validRecents()
        if coord.loadedRecents != valid || coord.reloadToken != reloadToken {
            coord.loadedRecents = valid
            coord.reloadToken = reloadToken
            coord.childCache.removeAll()
            coord.rebuildRootNodes()
            browser.loadColumnZero()
            coord.appliedSelection = "\u{1}"
        }

        // Reflect an externally-set active root / current dir (restore, ⌘↑, Open).
        let want = (activeRoot ?? "") + "\u{0}" + currentDir
        if coord.appliedSelection != want {
            coord.appliedSelection = want
            if let ip = coord.indexPath(root: activeRoot, dir: currentDir) {
                browser.selectionIndexPath = ip
            }
        }
    }

    // MARK: - Coordinator / NSBrowser delegate

    @MainActor
    final class Coordinator: NSObject, NSBrowserDelegate {
        var recents: [String]
        var onSelect: (String, String) -> Void
        var onRemove: (String) -> Void
        var showHidden = false
        var showNonCVS = false
        weak var browser: NSBrowser?
        var loadedRecents: [String] = []
        var reloadToken: Int = -1
        var appliedSelection: String = "\u{1}"
        var rootNodes: [BrowserNode] = []
        var childCache: [String: [BrowserNode]] = [:]
        nonisolated(unsafe) private var rightClickMonitor: Any?

        init(recents: [String], onSelect: @escaping (String, String) -> Void,
             onRemove: @escaping (String) -> Void) {
            self.recents = recents
            self.onSelect = onSelect
            self.onRemove = onRemove
        }

        deinit {
            if let m = rightClickMonitor { NSEvent.removeMonitor(m) }
        }

        // MARK: - Right-click "Forget" menu (via event monitor — reliable across
        // NSBrowser's internal column views, which swallow menu(for:)).

        func installRightClickMonitor() {
            guard rightClickMonitor == nil else { return }
            rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let browser = self.browser, event.window === browser.window else { return false }
                    let point = browser.convert(event.locationInWindow, from: nil)
                    guard browser.bounds.contains(point),
                          let node = self.node(at: point, in: browser),
                          node.isWorkingCopy else { return false }

                    let menu = NSMenu()
                    let forget = NSMenuItem(title: "Forget “\(node.name)”",
                                            action: #selector(self.forgetClicked(_:)), keyEquivalent: "")
                    forget.target = self
                    forget.representedObject = node.rootPath
                    menu.addItem(forget)
                    let reveal = NSMenuItem(title: "Reveal in Finder",
                                            action: #selector(self.revealClicked(_:)), keyEquivalent: "")
                    reveal.target = self
                    reveal.representedObject = node.rootPath
                    menu.addItem(reveal)

                    menu.popUp(positioning: nil, at: point, in: browser)
                    return true
                }
                return handled ? nil : event
            }
        }

        /// The node under a point in the browser's coordinate space, if any.
        private func node(at point: NSPoint, in browser: NSBrowser) -> BrowserNode? {
            var col = -1
            var c = 0
            while c <= browser.lastColumn {
                if browser.frame(ofColumn: c).contains(point) { col = c; break }
                c += 1
            }
            guard col >= 0 else { return nil }
            var r = 0
            while let item = browser.item(atRow: r, inColumn: col) {
                if browser.frame(ofRow: r, inColumn: col).contains(point) { return item as? BrowserNode }
                r += 1
                if r > 100_000 { break }
            }
            return nil
        }

        @objc func forgetClicked(_ sender: NSMenuItem) {
            if let path = sender.representedObject as? String { onRemove(path) }
        }

        @objc func revealClicked(_ sender: NSMenuItem) {
            if let path = sender.representedObject as? String {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }

        /// Recent working copies that still exist and are CVS checkouts.
        func validRecents() -> [String] {
            recents.filter { FileManager.default.fileExists(atPath: $0 + "/CVS") }
        }

        func rebuildRootNodes() {
            rootNodes = validRecents().map {
                BrowserNode(rootPath: $0, relPath: "", name: $0, isWorkingCopy: true)
            }
        }

        /// Children of a node (nil == column 0 → the working-copy roots).
        func children(of node: BrowserNode?) -> [BrowserNode] {
            guard let node else { return rootNodes }
            if let cached = childCache[node.absPath] { return cached }
            let abs = node.absPath
            var nodes: [BrowserNode] = []
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: abs)) ?? []
            where name != "CVS" && (showHidden || !name.hasPrefix(".")) {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: abs + "/" + name, isDirectory: &isDir), isDir.boolValue
                else { continue }
                // Hide non-CVS sub-directories unless asked to show them.
                let underCVS = fm.fileExists(atPath: abs + "/" + name + "/CVS")
                if !showNonCVS, !underCVS { continue }
                let rel = node.relPath.isEmpty ? name : node.relPath + "/" + name
                nodes.append(BrowserNode(rootPath: node.rootPath, relPath: rel,
                                         name: name, isWorkingCopy: false))
            }
            nodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            childCache[node.absPath] = nodes
            return nodes
        }

        /// IndexPath selecting a working copy and a sub-directory within it.
        func indexPath(root: String?, dir: String) -> IndexPath? {
            guard let root, let ri = rootNodes.firstIndex(where: { $0.rootPath == root })
            else { return nil }
            var ip = IndexPath(index: ri)
            guard !dir.isEmpty else { return ip }
            var current = rootNodes[ri]
            for comp in dir.split(separator: "/") {
                let kids = children(of: current)
                guard let idx = kids.firstIndex(where: { $0.name == String(comp) }) else { break }
                ip.append(idx)
                current = kids[idx]
            }
            return ip
        }

        @objc func browserClicked(_ sender: NSBrowser) {
            guard let ip = sender.selectionIndexPath, !ip.isEmpty,
                  let node = sender.item(at: ip) as? BrowserNode else { return }
            appliedSelection = node.rootPath + "\u{0}" + node.relPath
            onSelect(node.rootPath, node.relPath)
        }

        // Item-based NSBrowser delegate ----------------------------------------

        func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item as? BrowserNode).count
        }
        func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
            children(of: item as? BrowserNode)[index]
        }
        func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
            guard let node = item as? BrowserNode else { return false }
            return children(of: node).isEmpty
        }
        func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
            (item as? BrowserNode)?.name ?? ""
        }
    }
}
