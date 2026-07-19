import Foundation

/// Thin async wrapper around the `cvs` command-line tool.
///
/// Every call execs the binary directly via `Process` (no shell), so it is
/// unaffected by shell aliases/hooks and needs no quoting. Working directory is
/// always the working-copy root the user opened.
enum CVSService {

    /// The cvs binary **bundled inside the app** (Contents/Resources/cvs) — a
    /// self-contained universal build. We deliberately never use the system cvs.
    static func locateBinary() -> String? {
        if let res = Bundle.main.resourcePath {
            let bundled = res + "/cvs"
            if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        }
        return nil
    }

    /// Run cvs with the given arguments in `directory`. Never throws for a
    /// non-zero exit code (cvs diff returns 1 when differences exist); callers
    /// inspect `exitCode`/`stderr` themselves.
    static func run(_ args: [String], in directory: String) async -> CVSResult {
        let binary = locateBinary() ?? "/nonexistent/cvs"  // bundled cvs only; never system
        return await Task.detached(priority: .userInitiated) {
            runSync(binary: binary, args: args, directory: directory)
        }.value
    }

    /// Holds pipe output written by two dedicated reader threads (one per stream),
    /// so there is no shared-variable mutation across threads.
    private final class DataBox: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }

    /// Synchronous Process invocation. Runs on a background thread; reads both
    /// pipes on separate threads so large output can't deadlock.
    private static func runSync(binary: String, args: [String], directory: String) -> CVSResult {
        let pretty = "cvs " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: directory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            box.err = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try proc.run()
        } catch {
            return CVSResult(command: pretty, stdout: "",
                             stderr: "Failed to launch cvs: \(error.localizedDescription)",
                             exitCode: -1)
        }
        proc.waitUntilExit()
        group.wait()

        return CVSResult(
            command: pretty,
            stdout: String(data: box.out, encoding: .utf8) ?? "",
            stderr: String(data: box.err, encoding: .utf8) ?? "",
            exitCode: proc.terminationStatus
        )
    }

    // MARK: - High-level operations

    /// List a single directory (non-recursive): its sub-directories and files,
    /// each with CVS status and revision. Reads that dir's CVS/Entries locally,
    /// then overlays status letters from a dry-run `cvs -n -q update -l`.
    static func listDirectory(root: String, relDir: String, contactServer: Bool)
        async -> (items: [DirItem], log: CVSResult?)
    {
        let fm = FileManager.default
        let absDir = relDir.isEmpty ? root : root + "/" + relDir

        // 1. Local: this directory's Entries → file revisions + registered subdirs.
        var fileRev: [String: String] = [:]
        var entryDirs: Set<String> = []
        if let text = try? String(contentsOfFile: absDir + "/CVS/Entries", encoding: .utf8) {
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(raw)
                if line.hasPrefix("D/") {
                    let p = line.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
                    if p.count >= 2, !p[1].isEmpty { entryDirs.insert(String(p[1])) }
                } else if line.hasPrefix("/") {
                    let p = line.split(separator: "/", omittingEmptySubsequences: false)
                    if p.count >= 3, !p[1].isEmpty { fileRev[String(p[1])] = String(p[2]) }
                }
            }
        }

        // 2. Remote (optional): non-recursive dry-run update → status per name.
        var statusByName: [String: CVSStatus] = [:]
        var log: CVSResult? = nil
        if contactServer {
            let result = await run(["-n", "-q", "update", "-l"], in: absDir)
            log = result
            for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.count >= 3, line.dropFirst(1).first == " " else { continue }
                let code = line.first!
                var name = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if name.hasSuffix("/") { name.removeLast() }              // "? subdir/"
                guard !name.isEmpty, !name.contains("/") else { continue } // stay in this dir
                let status: CVSStatus
                switch code {
                case "M": status = .modified
                case "A": status = .added
                case "R": status = .removed
                case "U", "P": status = .needsUpdate
                case "G": status = .needsMerge
                case "C": status = .conflict
                case "?": status = .unknown
                default:  continue
                }
                statusByName[name] = status
            }
        }

        // 3. Filesystem listing of this directory.
        var items: [DirItem] = []
        var seenFiles: Set<String> = []
        let children = (try? fm.contentsOfDirectory(atPath: absDir)) ?? []
        for child in children where child != "CVS" {
            let childRel = relDir.isEmpty ? child : relDir + "/" + child
            var isDir: ObjCBool = false
            fm.fileExists(atPath: absDir + "/" + child, isDirectory: &isDir)
            if isDir.boolValue {
                let underCVS = entryDirs.contains(child)
                    || fm.fileExists(atPath: absDir + "/" + child + "/CVS")
                items.append(DirItem(name: child, relPath: childRel, isDirectory: true,
                                     revision: "",
                                     status: underCVS ? .upToDate : .unknown,
                                     underCVS: underCVS))
            } else {
                seenFiles.insert(child)
                let versioned = fileRev[child] != nil
                let status = statusByName[child] ?? (versioned ? .upToDate : .unknown)
                items.append(DirItem(name: child, relPath: childRel, isDirectory: false,
                                     revision: fileRev[child] ?? "",
                                     status: status, underCVS: versioned))
            }
        }
        // 4. In Entries but missing on disk.
        for (name, rev) in fileRev where !seenFiles.contains(name) {
            let childRel = relDir.isEmpty ? name : relDir + "/" + name
            items.append(DirItem(name: name, relPath: childRel, isDirectory: false,
                                 revision: rev, status: .missing, underCVS: true))
        }

        // Directories first, then files; each alphabetical.
        items.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return (items, log)
    }

    /// Fetch a file's base revision content to a temp file (network round-trip).
    /// Returns nil for added/unversioned files that have no prior revision.
    static func writeBaseRevision(root: String, relPath: String, revision: String) async -> String? {
        guard !revision.isEmpty, revision != "0", !revision.hasPrefix("-") else { return nil }
        let result = await run(["update", "-p", "-r", revision, relPath], in: root)
        guard !result.stdout.isEmpty else { return nil }

        let ext = (relPath as NSString).pathExtension
        let safeRel = relPath.replacingOccurrences(of: "/", with: "_")
        let safeRev = revision.replacingOccurrences(of: "/", with: "_")
        let stem = "maccvs-base-\(safeRel)-r\(safeRev)"
        let path = NSTemporaryDirectory() + (ext.isEmpty ? stem : "\(stem).\(ext)")
        do {
            try result.stdout.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    /// Run an arbitrary local tool (e.g. /usr/bin/diff) and capture its output.
    static func runTool(_ toolPath: String, _ args: [String], in directory: String) async -> CVSResult {
        await Task.detached(priority: .userInitiated) {
            runSync(binary: toolPath, args: args, directory: directory)
        }.value
    }

    /// Locally determine which versioned files in a directory are modified, by
    /// comparing each file's mtime to the timestamp CVS recorded in CVS/Entries.
    /// This is exactly how cvs decides a file "might be" modified — and needs no
    /// network. Returns [filename: isModified] for files whose timestamp parses.
    static func localModifiedStatus(root: String, relDir: String) -> [String: Bool] {
        let absDir = relDir.isEmpty ? root : root + "/" + relDir
        guard let text = try? String(contentsOfFile: absDir + "/CVS/Entries", encoding: .utf8) else {
            return [:]
        }
        let fm = FileManager.default
        var result: [String: Bool] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard line.hasPrefix("/") else { continue }   // file record: /name/rev/timestamp/opts
            let p = line.split(separator: "/", omittingEmptySubsequences: false)
            guard p.count >= 4, !p[1].isEmpty else { continue }
            let name = String(p[1])
            // Added files / merge results store non-date timestamps → skip (can't tell locally).
            guard let recorded = parseEntriesDate(String(p[3])) else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: absDir + "/" + name),
                  let mtime = attrs[.modificationDate] as? Date else {
                result[name] = true   // in Entries but gone/unreadable → treat as changed
                continue
            }
            // CVS timestamps are GMT, second precision — compare at whole seconds.
            result[name] = Int(mtime.timeIntervalSince1970) != Int(recorded.timeIntervalSince1970)
        }
        return result
    }

    /// Parse a CVS/Entries timestamp ("Mon Feb  3 12:08:00 2025", GMT, asctime).
    private static func parseEntriesDate(_ s: String) -> Date? {
        let collapsed = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: collapsed)
    }

    /// Launch an external tool (e.g. opendiff) without blocking. Returns an
    /// error message if the launch failed, or nil on success.
    static func launch(_ toolPath: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            return "\(toolPath) not found or not executable"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: toolPath)
        p.arguments = args
        do { try p.run(); return nil }
        catch { return error.localizedDescription }
    }

    /// Like `run`, but streams output chunks live via `onChunk` (called off the
    /// main thread) while still returning the full collected result.
    static func runStreaming(_ args: [String], in directory: String,
                             onChunk: @escaping @Sendable (String) -> Void) async -> CVSResult {
        let binary = locateBinary() ?? "/nonexistent/cvs"  // bundled cvs only; never system
        return await Task.detached(priority: .userInitiated) {
            runSyncStreaming(binary: binary, args: args, directory: directory, onChunk: onChunk)
        }.value
    }

    private static func runSyncStreaming(binary: String, args: [String], directory: String,
                                         onChunk: @escaping @Sendable (String) -> Void) -> CVSResult {
        let pretty = "cvs " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: directory)

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let box = DataBox()
        let group = DispatchGroup()
        // stdout → box.out ; stderr → box.err ; each drained on its own thread.
        func drain(_ handle: FileHandle, isErr: Bool) {
            group.enter()
            DispatchQueue.global().async {
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    if isErr { box.err.append(data) } else { box.out.append(data) }
                    if let s = String(data: data, encoding: .utf8) { onChunk(s) }
                }
                group.leave()
            }
        }
        drain(outPipe.fileHandleForReading, isErr: false)
        drain(errPipe.fileHandleForReading, isErr: true)

        do { try proc.run() }
        catch {
            return CVSResult(command: pretty, stdout: "",
                             stderr: "Failed to launch cvs: \(error.localizedDescription)",
                             exitCode: -1)
        }
        proc.waitUntilExit()
        group.wait()
        return CVSResult(command: pretty,
                         stdout: String(data: box.out, encoding: .utf8) ?? "",
                         stderr: String(data: box.err, encoding: .utf8) ?? "",
                         exitCode: proc.terminationStatus)
    }
}
