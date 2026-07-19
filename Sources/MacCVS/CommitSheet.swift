import SwiftUI

/// Commit sheet: pick which changed files to commit and enter a message.
struct CommitSheet: View {
    @EnvironmentObject var store: WorkingCopyStore
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var chosen: Set<String> = []

    private var committable: [DirItem] {
        store.items.filter { !$0.isDirectory && $0.status.isCommittable }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit Changes").font(.title3.bold())

            if committable.isEmpty {
                Text("No modified, added, or removed files to commit.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text("Files").font(.caption.bold()).foregroundStyle(.secondary)
                List {
                    ForEach(committable) { file in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(file.relPath) },
                            set: { on in
                                if on { chosen.insert(file.relPath) } else { chosen.remove(file.relPath) }
                            })
                        ) {
                            HStack {
                                Text(file.status.letter)
                                    .font(.body.monospaced().bold())
                                    .foregroundStyle(file.status.color)
                                Text(file.relPath)
                            }
                        }
                    }
                }
                .frame(height: 160)
                .border(Color(nsColor: .separatorColor))
            }

            Text("Message").font(.caption.bold()).foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.body.monospaced())
                .frame(height: 100)
                .border(Color(nsColor: .separatorColor))

            HStack {
                Text("\(chosen.count) file(s) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Commit") {
                    let paths = Array(chosen)
                    let msg = message
                    dismiss()
                    Task { await store.commit(message: msg, paths: paths) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // Pre-select everything committable, or the current table selection.
            let selected = store.selection.intersection(Set(committable.map(\.relPath)))
            chosen = selected.isEmpty ? Set(committable.map(\.relPath)) : selected
        }
    }
}
