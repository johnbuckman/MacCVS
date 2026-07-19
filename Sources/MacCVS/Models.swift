import SwiftUI

/// CVS working-file status, derived from `CVS/Entries` plus `cvs -n -q update`.
enum CVSStatus: String, Sendable {
    case upToDate       // in sync with repository
    case modified       // locally modified (M)
    case added          // scheduled for addition (A)
    case removed        // scheduled for removal (R)
    case needsUpdate    // server has a newer revision (U/P)
    case needsMerge     // local + remote changes, merge required (G)
    case conflict       // conflict on merge (C)
    case unknown        // not under version control (?)
    case missing        // in Entries but not on disk

    var label: String {
        switch self {
        case .upToDate:    return "Up to date"
        case .modified:    return "Modified"
        case .added:       return "Added"
        case .removed:     return "Removed"
        case .needsUpdate: return "Needs update"
        case .needsMerge:  return "Needs merge"
        case .conflict:    return "Conflict"
        case .unknown:     return "Unknown"
        case .missing:     return "Missing"
        }
    }

    /// One-letter badge, matching cvs update conventions.
    var letter: String {
        switch self {
        case .upToDate:    return "·"
        case .modified:    return "M"
        case .added:       return "A"
        case .removed:     return "R"
        case .needsUpdate: return "U"
        case .needsMerge:  return "G"
        case .conflict:    return "C"
        case .unknown:     return "?"
        case .missing:     return "!"
        }
    }

    var color: Color {
        switch self {
        case .upToDate:    return .secondary
        case .modified:    return .orange
        case .added:       return .green
        case .removed:     return .red
        case .needsUpdate: return .blue
        case .needsMerge:  return .purple
        case .conflict:    return .red
        case .unknown:     return .gray
        case .missing:     return .red
        }
    }

    /// Files a commit would actually act on.
    var isCommittable: Bool {
        self == .modified || self == .added || self == .removed
    }

    /// Sort priority so actionable files float to the top.
    var sortRank: Int {
        switch self {
        case .conflict:    return 0
        case .needsMerge:  return 1
        case .modified:    return 2
        case .added:       return 3
        case .removed:     return 4
        case .needsUpdate: return 5
        case .missing:     return 6
        case .unknown:     return 7
        case .upToDate:    return 8
        }
    }
}

/// One row in the directory browser: a sub-directory or a file in the current folder.
struct DirItem: Identifiable, Hashable, Sendable {
    var name: String          // display name (last path component)
    var relPath: String       // path relative to the working-copy root
    var isDirectory: Bool
    var revision: String       // "" for directories / unknown files
    var status: CVSStatus
    var underCVS: Bool         // dir has CVS/ ; file is in Entries

    var id: String { relPath.isEmpty ? name : relPath }

    /// A versioned file we can diff / commit / log.
    var isVersionedFile: Bool { !isDirectory && underCVS }
}

/// Result of running a cvs subcommand.
struct CVSResult: Sendable {
    var command: String       // human-readable command line, for the console
    var stdout: String
    var stderr: String
    var exitCode: Int32

    var combined: String {
        var s = stdout
        if !stderr.isEmpty {
            if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
            s += stderr
        }
        return s
    }
}
