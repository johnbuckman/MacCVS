// Debug control channel — lets a script (regression tests, or an agent making screenshots
// and explainer videos) drive MacCVS with no mouse: open working copies, select files, run
// every command, fill and press the commit sheets, and save PNG snapshots of MacCVS's own
// windows. Same design as SideStep's (InstallerApp/DebugControl.swift there).
//
// OFF unless a token is configured: env MACCVS_DEBUG_TOKEN, or the file
// ~/Library/Application Support/MacCVS/debug-token (must be chmod 600). Release builds carry
// the code but never listen without that file. Listens on 127.0.0.1 only.
//
// Wire protocol (TCP 127.0.0.1:51239), one command per line, any number per connection:
//   <token> CMD [args…]          args are space-separated; "double quotes" group words
// Each command gets exactly one reply line: JSON for queries, "OK …" or "ERR …" otherwise.
// Full list: HELP, and docs/DEBUG-CONTROL.md.
import AppKit
import Network
import SwiftUI

/// Commands for views that keep their own state (commit sheets, diff and log windows).
/// Posted on the main thread; each view acts only if it is in the targeted window.
extension Notification.Name {
    static let macCVSDebug = Notification.Name("MacCVSDebug")
}

struct DebugCommand {
    let cmd: String
    let args: [String]
    let window: NSWindow?     // the window meant (its sheet's parent), or nil = any
    static func from(_ n: Notification) -> DebugCommand? { n.object as? DebugCommand }
    /// True if a view living in `w` should act on this command.
    func targets(_ w: NSWindow?) -> Bool {
        guard let window else { return true }
        return w === window || w?.sheetParent === window || window.sheetParent === w
    }
}

@MainActor enum DebugControl {
    static let port: UInt16 = 51239
    private static var listener: NWListener?
    nonisolated(unsafe) private static var token = ""

    static var tokenFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacCVS/debug-token")
    }

    /// Start the listener if (and only if) a debug token is configured.
    static func startIfConfigured() {
        guard listener == nil else { return }
        var t = ProcessInfo.processInfo.environment["MACCVS_DEBUG_TOKEN"] ?? ""
        if t.isEmpty, let attrs = try? FileManager.default.attributesOfItem(atPath: tokenFile.path) {
            // refuse a token file other users could read
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            if perms & 0o077 != 0 { NSLog("MacCVS debug control: \(tokenFile.path) must be chmod 600"); return }
            t = ((try? String(contentsOf: tokenFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !t.isEmpty else { return }
        token = t
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { c in Session(c).start() }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
            NSLog("MacCVS debug control: listening on 127.0.0.1:\(port)")
        } catch { NSLog("MacCVS debug control: couldn't listen: \(error)") }
    }

    /// One client connection: read lines, answer each in order.
    private final class Session: @unchecked Sendable {
        let c: NWConnection
        var buf = Data()
        init(_ c: NWConnection) { self.c = c }
        func start() { c.start(queue: .global(qos: .userInitiated)); read() }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, err in
                if let data { buf.append(data) }
                drain()
                if done || err != nil { c.cancel() } else { read() }
            }
        }
        func drain() {
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
                buf.removeSubrange(buf.startIndex...nl)
                let reply = DebugControl.dispatch(line.trimmingCharacters(in: .whitespacesAndNewlines))
                let out = reply.replacingOccurrences(of: "\n", with: " ") + "\n"
                let sent = DispatchSemaphore(value: 0)
                c.send(content: out.data(using: .utf8), completion: .contentProcessed { _ in sent.signal() })
                sent.wait()
            }
        }
    }

    // MARK: getting onto the main thread — even while a modal panel is up
    //
    // Run-loop blocks registered for the modal-panel and event-tracking modes also run inside
    // runModal's loop (the update alert, Name Repository…), which DispatchQueue.main would not.
    nonisolated(unsafe) static let modes = [CFRunLoopMode.defaultMode.rawValue,
                                    "NSModalPanelRunLoopMode" as CFString,
                                    "NSEventTrackingRunLoopMode" as CFString] as CFArray
    nonisolated static func onMain<T>(_ f: @escaping @MainActor () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var r: T?
        CFRunLoopPerformBlock(CFRunLoopGetMain(), modes) { MainActor.assumeIsolated { r = f() }; done.signal() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        done.wait()
        return r!
    }

    /// Entry point from a connection (background thread). TYPE runs here so its pauses
    /// between letters don't hold the main thread; everything else runs on main.
    nonisolated static func dispatch(_ line: String) -> String {
        var w = split(line)
        guard w.count >= 2, w.removeFirst() == token else { return "ERR auth" }
        let cmd = w.removeFirst().uppercased()
        if cmd == "TYPE", w.count >= 2 {   // TYPE message <text> [chars/s]
            guard w[0].lowercased() == "message" else { return "ERR TYPE message <text> [chars/s]" }
            let text = w[1], cps = Double(w.count > 2 ? w[2] : "") ?? 12
            var s = ""
            for ch in text {
                s.append(ch)
                let typed = s
                let r = onMain { post("sheet-message", [typed]) }
                if r.hasPrefix("ERR") { return r }
                if cps > 0 { usleep(useconds_t(1e6 / cps)) }
            }
            return "OK"
        }
        if cmd == "WAIT" {   // WAIT idle [seconds]: until no cvs command is running
            let limit = Date().addingTimeInterval(Double(w.count > 1 ? w[1] : "") ?? 60)
            usleep(150_000)
            while Date() < limit {
                if !onMain({ WorkingCopyStore.current?.isBusy ?? false }) { return "OK" }
                usleep(100_000)
            }
            return "ERR still busy"
        }
        let args = w
        return onMain { handle(cmd, args) }
    }

    // MARK: dispatch

    static let help = "PING STATE WINDOWS ACTIVE OPEN PROJECT GO ENTER SELECT DO SORT VIEW DIFF SPLIT SHEET TYPE DIFFDO LOGDO SCROLL WINDOW CLOSE SNAP DEMO WAIT"

    static func handle(_ cmd: String, _ w: [String]) -> String {
        func arg(_ i: Int) -> String { i < w.count ? w[i] : "" }
        guard let s = WorkingCopyStore.current else { return "ERR no store" }
        switch cmd {
        case "HELP": return help
        case "PING":
            return "PONG " + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev")
        case "STATE": return json(state(s))
        case "WINDOWS": return json(windows())
        case "OPEN":      // OPEN <working copy path>: as File ▸ Open (goes to the front of the projects)
            s.open(arg(0)); return "OK"
        case "PROJECT":   // PROJECT <root> [dir]: as clicking it in the column browser
            s.browserSelect(root: arg(0), dir: arg(1)); return "OK"
        case "GO":        // GO <dir relative to the root>
            s.navigate(to: arg(0)); return "OK"
        case "ENTER":     // ENTER <name>: as double-clicking a row (folder → in, file → diff)
            guard let it = s.items.first(where: { $0.name == arg(0) }) else { return "ERR no item \(arg(0))" }
            s.selection = [it.id]; s.enter(it); return "OK"
        case "SELECT":    // SELECT <name>… | SELECT none
            if arg(0).lowercased() == "none" || w.isEmpty { s.selection = []; return "OK" }
            let ids = w.compactMap { n in s.items.first(where: { $0.name == n || $0.relPath == n })?.id }
            guard ids.count == w.count else { return "ERR not all found: \(w)" }
            s.selection = Set(ids); return "OK"
        case "DO":
            switch arg(0) {
            case "refresh": s.browserReloadToken += 1; Task { await s.refresh(contactServer: true) }
            case "rescan": s.localRescan()
            case "update": Task { await s.updateSelectedOrCurrentDir() }
            case "commit": s.showCommitSheet = true
            case "diff": Task { await s.diffSelected() }
            case "log": Task { await s.log() }
            case "add": Task { await s.add() }
            case "revert": Task { await s.revert() }
            case "up": s.goUp()
            case "clear-console": s.clearConsole()
            case "forget": s.removeRecent(arg(1))
            case "name-repo": s.setRepoName(arg(1), arg(2))
            case "check-updates": Task { await UpdateChecker.shared.check(userInitiated: true) }
            default: return "ERR DO refresh|rescan|update|commit|diff|log|add|revert|up|clear-console|forget <root>|name-repo <root> <name>|check-updates"
            }
            return "OK"
        case "SORT":      // SORT name|status|rev [asc|desc]  (the file list's @AppStorage)
            guard ["name", "status", "rev"].contains(arg(0)) else { return "ERR SORT name|status|rev [asc|desc]" }
            UserDefaults.standard.set(arg(0), forKey: "sortColumn")
            UserDefaults.standard.set(arg(1) != "desc", forKey: "sortAscending")
            return "OK"
        case "VIEW":      // VIEW hidden|noncvs on|off
            let on = arg(1) != "off"
            switch arg(0) {
            case "hidden": s.showHidden = on
            case "noncvs": s.showNonCVS = on
            default: return "ERR VIEW hidden|noncvs on|off"
            }
            return "OK"
        case "DIFF":      // DIFF side|unified|line|word  (the diff window's toggles)
            switch arg(0) {
            case "side": UserDefaults.standard.set(false, forKey: "diffUnified")
            case "unified": UserDefaults.standard.set(true, forKey: "diffUnified")
            case "line": UserDefaults.standard.set(false, forKey: "diffWordMode")
            case "word": UserDefaults.standard.set(true, forKey: "diffWordMode")
            default: return "ERR DIFF side|unified|line|word"
            }
            return "OK"
        case "SPLIT":     // SPLIT <0…1>: where the diff window's centre divider sits
            return post("diff-split", [arg(0)], findWindow("diff"))
        case "SHEET":     // SHEET message <text> | press | cancel | toggle <path>: the open commit sheet
            return post("sheet-" + arg(0), Array(w.dropFirst()))
        case "DIFFDO":    // DIFFDO commit | discard <file#> <hunk#> | discard-all <file#>
            return post("diff-" + arg(0), Array(w.dropFirst()), findWindow("diff"))
        case "LOGDO":     // LOGDO diffs on|off
            return post("log-" + arg(0), Array(w.dropFirst()), findWindow("log"))
        case "SCROLL":    // SCROLL <window> <y points from the top | bottom> [which scroll view: 0 = biggest]
            guard let win = findWindow(arg(0)) else { return "ERR no window \(arg(0))" }
            let views = allSubviews(win.contentView).compactMap { $0 as? NSScrollView }
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            let i = Int(arg(2)) ?? 0
            guard i < views.count, let doc = views[i].documentView else { return "ERR no scroll view" }
            let clip = views[i].contentView
            let maxY = max(0, doc.frame.height - clip.bounds.height)
            var y = arg(1) == "bottom" ? maxY : min(maxY, Double(arg(1)) ?? 0)
            if !doc.isFlipped { y = maxY - y }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            views[i].reflectScrolledClipView(clip)
            return "OK"
        case "WINDOW":    // WINDOW <window> <width> <height> [x y]: content size (points), optional origin
            guard let win = findWindow(arg(0)), let wd = Double(arg(1)), let ht = Double(arg(2)) else {
                return "ERR WINDOW <window> <width> <height> [x y]"
            }
            win.setContentSize(NSSize(width: wd, height: ht))
            if let x = Double(arg(3)), let y = Double(arg(4)) { win.setFrameTopLeftPoint(NSPoint(x: x, y: y)) }
            return "OK"
        case "CLOSE":
            guard let win = findWindow(arg(0)) else { return "ERR no window \(arg(0))" }
            win.close(); return "OK"
        case "SNAP":      // SNAP main|diff|log|key|<title>|#<number> <path> [scale]
            guard let win = findWindow(arg(0)) else { return "ERR no window \(arg(0))" }
            let path = arg(1).isEmpty ? NSTemporaryDirectory() + "maccvs-snap.png" : (arg(1) as NSString).expandingTildeInPath
            let scale = Double(arg(2)) ?? 2
            guard let png = snapshot(win, scale: scale) else { return "ERR snapshot failed" }
            do { try png.data.write(to: URL(fileURLWithPath: path)) } catch { return "ERR \(error.localizedDescription)" }
            return json(["path": path, "width": png.width, "height": png.height, "title": win.title,
                         "sheet": win.attachedSheet != nil, "active": NSApp.isActive])
        case "VIEWS":     // VIEWS <window>: the title bar's view tree (class, frame in the frame view), for debugging SNAP
            guard let win = findWindow(arg(0)), let content = win.contentView, let fv = content.superview else { return "ERR no window" }
            return json(allSubviews(fv).filter { !$0.isDescendant(of: content) }.map { v -> String in
                let f = v.convert(v.bounds, to: fv)
                return "\(type(of: v)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\(v.isHidden ? " hidden" : "")\(v.wantsLayer ? " L" : "")"
            })
        case "SNAPVIEW":  // SNAPVIEW <window> <class prefix> <index> <path>: one title-bar view, for debugging SNAP
            guard let win = findWindow(arg(0)), let content = win.contentView, let fv = content.superview else { return "ERR no window" }
            let vs = allSubviews(fv).filter { !$0.isDescendant(of: content) && String(describing: type(of: $0)).hasPrefix(arg(1)) }
            guard let i = Int(arg(2)), i < vs.count, let rep = cache(vs[i], 2),
                  let d = rep.representation(using: .png, properties: [:]) else { return "ERR no such view (\(vs.count))" }
            try? d.write(to: URL(fileURLWithPath: arg(3)))
            return "OK \(vs.count) white=\(whiteOnly(rep)) \(type(of: vs[i]))"
        case "MENU":      // MENU more | close: open the toolbar's More menu (replies first: the menu tracks modally)
            if arg(0) == "close" {
                for w in NSApp.windows where String(describing: type(of: w)).contains("Menu") { (w.contentView as? NSView)?.window?.orderOut(nil) }
                NSApp.mainMenu?.cancelTracking()
                for b in allButtons(findWindow("main")) { b.menu?.cancelTracking() }
                return "OK"
            }
            guard let win = findWindow("main"), let content = win.contentView, let fv = content.superview,
                  let pop = allSubviews(fv).first(where: { String(describing: type(of: $0)).contains("PopupButton") }) as? NSControl
            else { return "ERR no More button" }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                CFRunLoopPerformBlock(CFRunLoopGetMain(), modes) { MainActor.assumeIsolated { pop.performClick(nil) } }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            return "OK"
        case "ACTIVATE":  // bring MacCVS to the front (a window draws its toolbar properly only while the app is active)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderedWindows.first { kind($0) == "main" && $0.isVisible }?.makeKeyAndOrderFront(nil)
            return "OK"
        case "ACTIVE":    // ACTIVE on|off: draw as the key window (see DebugAppearance)
            DebugAppearance.shared.forceActive = arg(0) != "off"; return "OK"
        case "DEMO":      // DEMO alias "<real>" "<shown>" | clear | list
            switch arg(0) {
            case "alias":
                guard !arg(1).isEmpty else { return "ERR DEMO alias <from> <to>" }
                Demo.aliases[arg(1)] = arg(2)
            case "clear": Demo.aliases = [:]
            case "list": return json(Demo.aliases)
            default: return "ERR DEMO alias|clear|list"
            }
            s.browserReloadToken += 1
            s.objectWillChange.send()
            return "OK"
        default:
            return "ERR unknown command \(cmd) (\(help))"
        }
    }

    static func post(_ cmd: String, _ args: [String], _ window: NSWindow? = nil) -> String {
        NotificationCenter.default.post(name: .macCVSDebug, object: DebugCommand(cmd: cmd, args: args, window: window))
        return "OK"
    }

    // MARK: state

    static func state(_ s: WorkingCopyStore) -> [String: Any] {
        [
            "root": s.root ?? "", "dir": s.currentDir, "busy": s.isBusy, "status": s.statusLine,
            "running": s.runningCommand, "selection": Array(s.selection).sorted(), "recents": s.recents,
            "commitSheet": s.showCommitSheet,
            "items": s.items.map { ["name": $0.name, "dir": $0.isDirectory, "status": $0.status.label, "rev": $0.revision] },
            "windows": windows(),
        ]
    }

    static func windows() -> [[String: Any]] {
        NSApp.windows.filter { $0.isVisible }.map { w in
            ["number": w.windowNumber, "title": w.title, "kind": kind(w), "class": String(describing: type(of: w)), "key": w.isKeyWindow, "sheet": w.isSheet,
             "frame": [w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height]]
        }
    }

    static func kind(_ w: NSWindow) -> String {
        if w.isSheet { return "sheet" }
        let vc = w.contentViewController.map { String(describing: type(of: $0)) } ?? ""
        if vc.contains("DiffView") { return "diff" }
        if vc.contains("LogView") { return "log" }
        if w is NSPanel { return "panel" }
        return "main"
    }

    static func findWindow(_ key: String) -> NSWindow? {
        let vis = NSApp.windows.filter { $0.isVisible && !$0.isSheet }
        switch key.lowercased() {
        case "", "key": return NSApp.keyWindow
        case "main", "diff", "log":   // the frontmost of that kind
            return NSApp.orderedWindows.first { $0.isVisible && kind($0) == key.lowercased() }
        default:
            if key.hasPrefix("#"), let n = Int(key.dropFirst()) { return vis.first { $0.windowNumber == n } }
            return vis.first { $0.title.localizedCaseInsensitiveContains(key) }
        }
    }

    static func allButtons(_ w: NSWindow?) -> [NSButton] {
        guard let fv = w?.contentView?.superview else { return [] }
        return allSubviews(fv).compactMap { $0 as? NSButton }
    }

    static func allSubviews(_ v: NSView?) -> [NSView] {
        guard let v else { return [] }
        return [v] + v.subviews.flatMap { allSubviews($0) }
    }

    // MARK: snapshots

    /// PNG of a window drawn by the app itself (title bar included; no Screen Recording
    /// permission, nothing on screen disturbed), with an attached sheet drawn in place.
    /// `scale` 2 gives a crisp 2x image on a 1x display.
    static func snapshot(_ w: NSWindow, scale: Double) -> (data: Data, width: Int, height: Int)? {
        guard let base = render(w, scale: scale) else { return nil }
        guard let sheet = w.attachedSheet, let top = render(sheet, scale: scale) else {
            guard let d = base.representation(using: .png, properties: [:]) else { return nil }
            return (d, base.pixelsWide, base.pixelsHigh)
        }
        let size = NSSize(width: base.pixelsWide, height: base.pixelsHigh)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        base.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.12).setFill()     // the dimming macOS puts behind a sheet
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        // sheet position relative to the window, in pixels (both frames are in screen points, origin bottom-left)
        let sf = sheet.frame, wf = w.frame
        let r = NSRect(x: (sf.minX - wf.minX) * scale, y: (sf.minY - wf.minY) * scale,
                       width: Double(top.pixelsWide), height: Double(top.pixelsHigh))
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        let clip = NSBezierPath(roundedRect: r, xRadius: 10 * scale, yRadius: 10 * scale)
        NSColor.windowBackgroundColor.setFill()
        clip.fill()
        NSShadow().set()
        clip.addClip()
        top.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let d = out.representation(using: .png, properties: [:]) else { return nil }
        return (d, out.pixelsWide, out.pixelsHigh)
    }

    /// The window at `scale`, assembled from pieces, because caching the whole window frame
    /// leaves out everything SwiftUI hosts in layers (the content and toolbar items come out
    /// blank): the content view, then the title bar band from the frame view, then each SwiftUI
    /// toolbar item drawn on its own, then the traffic lights in colour (a window that isn't
    /// key draws them grey, and the demo window is never key).
    static func render(_ w: NSWindow, scale: Double) -> NSBitmapImageRep? {
        guard let content = w.contentView, let frameView = content.superview else { return nil }
        let r = frameView.bounds
        // toolbar items whose label is white, meant for the accent colour (.borderedProminent: the
        // Commit button). Worked out before our drawing context is current: cacheDisplay misdraws inside it.
        let items = allSubviews(frameView).filter { !$0.isDescendant(of: content) && !$0.isHiddenOrHasHiddenAncestor
            && String(describing: type(of: $0)).hasPrefix("ToolbarItemHostingView") }
        // An inactive window draws it grey with a dark label instead, so the one wide item (the
        // icon buttons are under 50 pt) gets the accent capsule, and its label is drawn here.
        var prominent: [NSRect] = [], unlabelled: [NSRect] = [], skip: [NSView] = [], labelled: [NSView] = []
        for v in items {
            guard let rep = cache(v, scale) else { continue }
            let f0 = v.convert(v.bounds, to: frameView)
            let f = frameView.isFlipped ? NSRect(x: f0.minX, y: r.height - f0.maxY, width: f0.width, height: f0.height) : f0
            if whiteOnly(rep) { prominent.append(f); labelled.append(v); skip.append(v) }
            else if f.width >= 60 { prominent.append(f); unlabelled.append(f); skip.append(v) }
        }
        // title and subtitle, in the key window's colours (an inactive window greys them)
        let titles = allSubviews(frameView).compactMap { $0 as? NSTextField }
            .filter { !$0.isDescendant(of: content) && !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty }
            .sorted { $0.convert($0.bounds, to: frameView).maxY > $1.convert($1.bounds, to: frameView).maxY }
        guard let out = bitmap(r.size, scale), let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        func flipY(_ rect: NSRect) -> NSRect {       // frame-view rect → bottom-left drawing rect
            frameView.isFlipped ? NSRect(x: rect.minX, y: r.height - rect.maxY, width: rect.width, height: rect.height) : rect
        }
        func place(_ v: NSView, tint: NSColor? = nil) {
            guard v.bounds.width > 0, v.bounds.height > 0, var rep = cache(v, scale) else { return }
            if let tint, let tinted = recolor(rep, tint) { rep = tinted }
            rep.draw(in: flipY(v.convert(v.bounds, to: frameView)), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let band = r.height - w.contentLayoutRect.height                 // title bar + toolbar height
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: r.width, height: r.height).fill()
        if let rep = cache(content, scale) {                             // the content, below the band
            let cr = flipY(content.convert(content.bounds, to: frameView))
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: 0, y: 0, width: r.width, height: r.height - band).clip()
            rep.draw(in: cr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let chrome = allSubviews(frameView).filter { !$0.isDescendant(of: content) && !$0.isHiddenOrHasHiddenAncestor }
        func named(_ s: String) -> [NSView] { chrome.filter { String(describing: type(of: $0)).hasPrefix(s) } }
        // the toolbar's glass capsules (macOS 26 draws them in the window server, so draw them here)
        for v in named("NSToolbarPlatterView") {
            let f = flipY(v.convert(v.bounds, to: frameView))
            let cap = NSBezierPath(roundedRect: f, xRadius: f.height / 2, yRadius: f.height / 2)
            let accent = prominent.contains { $0.intersects(f) }
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowBlurRadius = 6; sh.shadowOffset = NSSize(width: 0, height: -1)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.10); sh.set()
            (accent ? NSColor.controlAccentColor : NSColor(white: 0.985, alpha: 1)).setFill(); cap.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.07).setStroke(); cap.lineWidth = 0.5; cap.stroke()
        }
        // each toolbar item, and the title + subtitle
        // icons in the key window's colour (inactive windows grey them); alpha is kept, so a
        // disabled button stays faint
        // (MacCVS's toolbar, left to right: Open, Refresh, divider, Diff, Update, Commit, More)
        let icons = named("ToolbarItemHostingView").filter { !skip.contains($0) }
            .sorted { $0.convert($0.bounds, to: frameView).minX < $1.convert($1.bounds, to: frameView).minX }
        let noDiff = WorkingCopyStore.current?.selectedVersionedFiles.isEmpty ?? true
        for (i, v) in icons.enumerated() {
            if v.bounds.height < 4 { place(v, tint: .tertiaryLabelColor); continue }          // the divider
            if i == 3 && noDiff { place(v, tint: .tertiaryLabelColor); continue }             // Diff, disabled
            place(v, tint: .labelColor)
            if i == icons.count - 1 { place(v, tint: .labelColor) }   // More: an inactive pop-up is faint, so twice
        }
        for (i, field) in titles.enumerated() {
            let f = flipY(field.convert(field.bounds, to: frameView))
            let s = NSAttributedString(string: field.stringValue, attributes: [
                .font: field.font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: i == 0 ? NSColor.labelColor : NSColor.secondaryLabelColor])
            s.draw(at: NSPoint(x: f.minX + 2, y: f.midY - s.size().height / 2))
        }
        for v in labelled { place(v) }   // its own white label (drawn when the app is active)
        for f in unlabelled {   // the Commit button's label, as the key window draws it
            let font = NSFont.systemFont(ofSize: 13, weight: .medium)
            let text = NSAttributedString(string: "Commit", attributes: [.font: font, .foregroundColor: NSColor.white])
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium).applying(.init(paletteColors: [.controlAccentColor, .white]))
            let icon = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            let iw = icon?.size.width ?? 0, gap: CGFloat = 5, ts = text.size()
            var x = f.midX - (iw + gap + ts.width) / 2
            if let icon { icon.draw(in: NSRect(x: x, y: f.midY - icon.size.height / 2, width: iw, height: icon.size.height)); x += iw + gap }
            text.draw(at: NSPoint(x: x, y: f.midY - ts.height / 2))
        }
        let lights: [(NSWindow.ButtonType, NSColor)] = [
            (.closeButton, NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1)),
            (.miniaturizeButton, NSColor(red: 1.0, green: 0.74, blue: 0.18, alpha: 1)),
            (.zoomButton, NSColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)),
        ]
        for (type, color) in lights {
            guard let b = w.standardWindowButton(type), !b.isHidden else { continue }
            let f = flipY(b.convert(b.bounds, to: frameView))
            let d = min(f.width, f.height) - 2
            let dot = NSRect(x: f.midX - d / 2, y: f.midY - d / 2, width: d, height: d)
            color.setFill(); NSBezierPath(ovalIn: dot).fill()
            color.blended(withFraction: 0.25, of: .black)?.setStroke()
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25)); ring.lineWidth = 0.5; ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// True if what's drawn is all white (a label meant for a coloured capsule).
    static func whiteOnly(_ rep: NSBitmapImageRep) -> Bool {
        var white = 0, dark = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.6 else { continue }
                if c.brightnessComponent > 0.92 && c.saturationComponent < 0.1 { white += 1 } else { dark += 1 }
            }
        }
        return white > 20 && dark * 10 < white
    }

    /// The same picture in one colour, each pixel keeping its alpha.
    static func recolor(_ rep: NSBitmapImageRep, _ color: NSColor) -> NSBitmapImageRep? {
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        out.size = rep.size     // before the context is made, so it draws in points
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let r = NSRect(origin: .zero, size: rep.size)
        rep.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill()
        r.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// True if nothing at all is drawn.
    static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { return false }
        }
        return true
    }

    static func bitmap(_ size: NSSize, _ scale: Double) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size   // points → pixels at `scale`, so a 1x screen still gives a crisp 2x image
        return rep
    }

    static func cache(_ v: NSView, _ scale: Double) -> NSBitmapImageRep? {
        guard let rep = bitmap(v.bounds.size, scale) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    // MARK: helpers

    /// Split on spaces, keeping "double-quoted phrases" together.
    nonisolated static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, has = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); has = true }
            else if ch == " " && !quoted { if has || !cur.isEmpty { out.append(cur) }; cur = ""; has = false }
            else { cur.append(ch) }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }
    nonisolated static func json(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "ERR json" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// ACTIVE on: SwiftUI draws controls as in the key window (the prominent Commit button,
/// selection colours) although the demo window is never key, so snapshots look as they
/// would to someone using the app.
@MainActor final class DebugAppearance: ObservableObject {
    static let shared = DebugAppearance()
    @Published var forceActive = false
}

struct DebugActive: ViewModifier {
    @ObservedObject private var look = DebugAppearance.shared
    @Environment(\.controlActiveState) private var real
    func body(content: Content) -> some View {
        content.environment(\.controlActiveState, look.forceActive ? .key : real)
    }
}

extension View {
    func debugActive() -> some View { modifier(DebugActive()) }
}

/// Display-only text substitution for screenshots and videos (DEMO alias), so real
/// repository paths, servers and user names never appear. Empty unless set over the
/// debug channel.
@MainActor enum Demo {
    static var aliases: [String: String] = [:]
    static func s(_ text: String) -> String {
        guard !aliases.isEmpty else { return text }
        var t = text
        // longest first, so "/Users/x/proj" wins over "/Users/x"
        for (k, v) in aliases.sorted(by: { $0.key.count > $1.key.count }) {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }
}
