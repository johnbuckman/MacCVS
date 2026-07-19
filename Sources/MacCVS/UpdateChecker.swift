import Foundation
import AppKit

/// Checks GitHub Releases once every 24h for a newer build. If one is found it
/// offers an Update/Cancel prompt; on Update it downloads the release zip,
/// verifies it is genuinely notarized, swaps the app bundle after quit, and
/// relaunches into the new version.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let releasesAPI = URL(string: "https://api.github.com/repos/johnbuckman/MacCVS/releases")!
    private let releasesPage = URL(string: "https://github.com/johnbuckman/MacCVS/releases")!
    private let lastCheckKey = "lastUpdateCheck"
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private let teamID = "XLS3XF57J8"   // required Developer ID team of any downloaded build
    private var busy = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    struct Release { let tag: String; let name: String; let zipURL: URL }

    // MARK: - Scheduling

    /// Run a check if 24h have passed since the last one (call at launch).
    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        guard let release = await fetchLatestRelease() else {
            if userInitiated { alert("Couldn’t Check for Updates", "Please try again later.") }
            return
        }
        if isNewer(release.tag, than: currentVersion) {
            presentUpdate(release)
        } else if userInitiated {
            alert("You’re Up to Date", "MacCVS \(currentVersion) is the latest version.")
        }
    }

    // MARK: - GitHub

    private func fetchLatestRelease() async -> Release? {
        var req = URLRequest(url: releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacCVS", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,                                   // releases are newest-first
              let tag = first["tag_name"] as? String,
              let assets = first["assets"] as? [[String: Any]] else { return nil }
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let urlStr = zip["browser_download_url"] as? String,
              let url = URL(string: urlStr) else { return nil }
        return Release(tag: tag, name: (first["name"] as? String) ?? tag, zipURL: url)
    }

    /// Compare version tags like "v0.2-alpha": numeric parts first, then
    /// prerelease rank (alpha < beta < rc < release).
    func isNewer(_ latest: String, than current: String) -> Bool {
        key(current).lexicographicallyPrecedes(key(latest))
    }

    private func key(_ tag: String) -> [Int] {
        var s = tag.lowercased()
        if s.hasPrefix("v") { s.removeFirst() }
        let rank = s.contains("alpha") ? 0 : s.contains("beta") ? 1 : (s.contains("rc") ? 2 : 3)
        let main = s.split(separator: "-").first.map(String.init) ?? s
        var nums = main.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        while nums.count < 3 { nums.append(0) }
        return Array(nums.prefix(3)) + [rank]
    }

    // MARK: - Prompt

    private func presentUpdate(_ release: Release) {
        let a = NSAlert()
        a.messageText = "A New Version of MacCVS Is Available"
        a.informativeText = "MacCVS \(release.tag) is available — you have \(currentVersion).\n\n"
            + "Click Update to download it and relaunch into the new version."
        a.addButton(withTitle: "Update")   // OK
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            Task { await downloadAndApply(release) }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: - Download & apply

    private func downloadAndApply(_ release: Release) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        let bundlePath = Bundle.main.bundlePath
        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            alert("Can’t Update Automatically",
                  "MacCVS is in a read-only location. Opening the Releases page so you can download the update manually.")
            NSWorkspace.shared.open(releasesPage)
            return
        }

        let zipURL = release.zipURL
        let teamID = self.teamID
        let newApp: String? = await Task.detached(priority: .userInitiated) {
            await Self.prepare(zipURL: zipURL, requiredTeamID: teamID)
        }.value

        guard let newApp else {
            alert("Update Failed",
                  "The update couldn’t be downloaded or verified. Opening the Releases page instead.")
            NSWorkspace.shared.open(releasesPage)
            return
        }
        launchUpdaterAndQuit(newApp: newApp, dest: bundlePath)
    }

    /// Download the zip, unzip it, locate MacCVS.app, and confirm it is notarized
    /// and signed by the expected team. Returns the path to the verified .app.
    private static func prepare(zipURL: URL, requiredTeamID: String) async -> String? {
        let fm = FileManager.default
        let work = NSTemporaryDirectory() + "maccvs-update-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)

        guard let (tmp, _) = try? await URLSession.shared.download(from: zipURL) else { return nil }
        let zipPath = work + "/update.zip"
        try? fm.moveItem(atPath: tmp.path, toPath: zipPath)

        // Unzip.
        let extractDir = work + "/x"
        _ = await CVSService.runTool("/usr/bin/ditto", ["-x", "-k", zipPath, extractDir], in: work)
        guard let appName = (try? fm.contentsOfDirectory(atPath: extractDir))?
            .first(where: { $0.hasSuffix(".app") }) else { return nil }
        let appPath = extractDir + "/" + appName

        // Must be accepted by Gatekeeper (i.e. notarized) …
        let assess = await CVSService.runTool("/usr/sbin/spctl", ["--assess", "--type", "exec", "-v", appPath], in: work)
        guard assess.combined.lowercased().contains("accepted") else { return nil }
        // … and signed by the expected Developer ID team.
        let cs = await CVSService.runTool("/usr/bin/codesign", ["-dv", "--verbose=4", appPath], in: work)
        guard cs.combined.contains("TeamIdentifier=\(requiredTeamID)") else { return nil }

        return appPath
    }

    private func launchUpdaterAndQuit(newApp: String, dest: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        NEWAPP="\(newApp)"
        DEST="\(dest)"
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        /usr/bin/ditto "$NEWAPP" "$DEST.updating" || exit 1
        /bin/rm -rf "$DEST"
        /bin/mv "$DEST.updating" "$DEST"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        /usr/bin/open "$DEST"
        """
        let scriptPath = NSTemporaryDirectory() + "maccvs-update-\(pid).sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [scriptPath]
            try p.run()                 // detached; keeps running after we quit
            NSApp.terminate(nil)
        } catch {
            alert("Update Failed", "Couldn’t start the updater: \(error.localizedDescription)")
        }
    }
}
