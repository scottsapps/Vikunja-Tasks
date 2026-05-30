import SwiftUI

struct AddTaskView: View {
    @Bindable var store: WatchStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var parsed: QuickAddResult?

    var body: some View {
        VStack(spacing: 8) {
            TextField("New task", text: $text)
                .onSubmit { parse() }
            if let p = parsed {
                ParsedChips(result: p)
                Button("Add") {
                    Task { await store.create(from: p); dismiss() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Review") { parse() }
                    .disabled(text.isEmpty)
            }
        }
        .navigationTitle("New Task")
    }

    private func parse() {
        let normalized = DictationNormalizer.normalize(text)
        parsed = QuickAddParser.parse(normalized,
                                      knownProjects: store.projects,
                                      knownLabels: store.labels)
    }
}
