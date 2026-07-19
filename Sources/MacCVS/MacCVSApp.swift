import SwiftUI

@main
struct MacCVSApp: App {
    @StateObject private var store = WorkingCopyStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Working Copy…") { openWorkingCopy() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    if store.recents.isEmpty {
                        Text("No recent working copies").disabled(true)
                    } else {
                        ForEach(store.recents, id: \.self) { path in
                            Button((path as NSString).lastPathComponent + "  —  " + path) {
                                store.open(path)
                            }
                        }
                    }
                }
            }
            // Add to the EXISTING View menu (don't create a second one).
            CommandGroup(after: .toolbar) {
                Toggle("Show Hidden Files", isOn: $store.showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Toggle("Show Non-CVS Files", isOn: $store.showNonCVS)
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandMenu("CVS") {
                Button("Refresh Status") { Task { await store.refresh(contactServer: true) } }
                    .keyboardShortcut("r")
                    .disabled(store.root == nil)
                Divider()
                Button("Update") { Task { await store.updateSelectedOrCurrentDir() } }
                    .keyboardShortcut("u")
                    .disabled(store.root == nil)
                Button("Commit…") { store.showCommitSheet = true }
                    .keyboardShortcut("k")
                    .disabled(store.root == nil)
                Divider()
                Button("Diff Selected") { Task { await store.diffSelected() } }
                    .keyboardShortcut("d")
                    .disabled(store.selectedVersionedFiles.isEmpty)
                Button("Log Selected") { Task { await store.log() } }
                    .keyboardShortcut("l")
                    .disabled(store.selection.isEmpty)
                Button("Add Selected") { Task { await store.add() } }
                    .disabled(store.selection.isEmpty)
                Button("Revert Selected") { Task { await store.revert() } }
                    .disabled(store.selection.isEmpty)
                Divider()
                Button("Enclosing Folder") { store.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(store.root == nil || store.currentDir.isEmpty)
            }
        }
    }

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
}
