import AppKit
import SwiftUI

/// How the app was launched, parsed from the command line.
///
///   MacCVS [DIR]                 open a CVS working copy directory
///   MacCVS --open DIR            open a CVS working copy directory
///   MacCVS --diff FILE           show the CVS diff (repo vs working copy) of FILE
///   MacCVS --diff LEFT RIGHT     show a visual diff between two files
///   MacCVS --help
enum LaunchMode {
    case normal
    case openDir(String)
    case diff([String])              // cvs diff of one or more working-copy files
    case compare(String, String)     // visual diff of two arbitrary files

    static let current: LaunchMode = parse()
    static var isDiffOnly: Bool {
        switch current { case .diff, .compare: return true; default: return false }
    }

    private static func parse() -> LaunchMode {
        let args = Array(CommandLine.arguments.dropFirst())
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--help", "-h":
                FileHandle.standardOutput.write(Data(usage.utf8)); exit(0)
            case "--diff":
                let files = args[(i + 1)...].prefix { !$0.hasPrefix("-") }.map(resolve)
                if !files.isEmpty { return .diff(Array(files)) }
            case "--compare":
                let f = args[(i + 1)...].prefix { !$0.hasPrefix("-") }.map(resolve)
                if f.count >= 2 { return .compare(f[0], f[1]) }
            case "--open":
                if i + 1 < args.count { return .openDir(resolve(args[i + 1])) }
            default:
                // A bare (non-flag) argument is a directory to open. Ignore the
                // -NSxxx / -psn_ arguments macOS sometimes injects.
                if !a.hasPrefix("-") { return .openDir(resolve(a)) }
            }
            i += 1
        }
        return .normal
    }

    /// Resolve a possibly-relative path against the launching shell's directory.
    private static func resolve(_ p: String) -> String {
        p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
    }

    static let usage = """
    MacCVS — native CVS client for macOS

    Usage:
      MacCVS [DIRECTORY]           Open a CVS working-copy directory
      MacCVS --open DIRECTORY      Open a CVS working-copy directory
      MacCVS --diff FILE...        Show the CVS diff (repo vs working copy) of one
                                   or more files, together in one window
      MacCVS --compare LEFT RIGHT  Show a visual diff between two arbitrary files
      MacCVS --help               Show this help

    In --diff / --compare mode MacCVS shows only the diff window and quits when it
    is closed, so other programs can use it as a graphical diff viewer, e.g.:

      MacCVS --diff  lib/a.tcl lib/b.tcl lib/c.tcl
      MacCVS --compare old.txt new.txt

    """
}

/// Produces a diff window for a `--diff` launch, then relies on
/// terminate-after-last-window to quit when the window is closed.
@MainActor
enum CLIDiff {
    /// CVS diff (repo vs working copy) of one or more files, in one window.
    static func diff(_ paths: [String]) async {
        var files: [DiffFile] = []
        for f in paths {
            let dir = (f as NSString).deletingLastPathComponent
            let name = (f as NSString).lastPathComponent
            let r = await CVSService.run(["diff", "-u", name], in: dir.isEmpty ? "." : dir)
            files += CVSDiffParser.parse(r.stdout)
                .map { DiffFile(path: f, hunks: $0.hunks) }
                .filter { !$0.hunks.isEmpty }
        }
        show(files, title: paths.count == 1 ? paths[0] : "\(paths.count) files")
    }

    /// Visual diff between two arbitrary files (local `diff`).
    static func compare(_ left: String, _ right: String) async {
        let r = await CVSService.runTool("/usr/bin/diff", ["-u", left, right], in: "/")
        let files = CVSDiffParser.parse(r.stdout)
            .map { DiffFile(path: (right as NSString).lastPathComponent, hunks: $0.hunks) }
        show(files, title: "\((left as NSString).lastPathComponent) ↔ \((right as NSString).lastPathComponent)")
    }

    private static func show(_ files: [DiffFile], title: String) {
        if files.contains(where: { !$0.hunks.isEmpty }) {
            DiffWindowManager.shared.present(DiffPayload(title: title, files: files))
        } else {
            let a = NSAlert()
            a.messageText = "No differences."
            a.runModal()
            NSApp.terminate(nil)
        }
    }
}

/// A zero-size view that closes its own window immediately — used as the
/// WindowGroup content in --diff mode so no main window appears.
struct WindowCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in v?.window?.close() }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
