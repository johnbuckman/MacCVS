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
    case diff([String])

    static let current: LaunchMode = parse()
    static var isDiffOnly: Bool { if case .diff = current { return true }; return false }

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
                return .diff(Array(files))
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
      MacCVS [DIRECTORY]          Open a CVS working-copy directory
      MacCVS --open DIRECTORY     Open a CVS working-copy directory
      MacCVS --diff FILE          Show the CVS diff (repository vs working copy) of FILE
      MacCVS --diff LEFT RIGHT    Show a visual diff between two files
      MacCVS --help              Show this help

    In --diff mode MacCVS shows only the diff window and quits when it is closed,
    so other programs can use it as a graphical diff viewer, e.g.:

      MacCVS --diff old.txt new.txt

    """
}

/// Produces a diff window for a `--diff` launch, then relies on
/// terminate-after-last-window to quit when the window is closed.
@MainActor
enum CLIDiff {
    static func present(_ paths: [String]) async {
        var payload: DiffPayload?
        if paths.count >= 2 {
            // Two arbitrary files → local diff.
            let left = paths[0], right = paths[1]
            let r = await CVSService.runTool("/usr/bin/diff", ["-u", left, right], in: "/")
            let files = CVSDiffParser.parse(r.stdout)
                .map { DiffFile(path: (right as NSString).lastPathComponent, hunks: $0.hunks) }
            payload = DiffPayload(title: "\((left as NSString).lastPathComponent) ↔ \((right as NSString).lastPathComponent)",
                                  files: files)
        } else if let f = paths.first {
            // One file in a working copy → cvs diff (repo vs working).
            let dir = (f as NSString).deletingLastPathComponent
            let name = (f as NSString).lastPathComponent
            let r = await CVSService.run(["diff", "-u", name], in: dir.isEmpty ? "." : dir)
            let files = CVSDiffParser.parse(r.stdout).map { DiffFile(path: f, hunks: $0.hunks) }
            payload = DiffPayload(title: f, files: files)
        }

        if let payload, payload.files.contains(where: { !$0.hunks.isEmpty }) {
            DiffWindowManager.shared.present(payload)
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
