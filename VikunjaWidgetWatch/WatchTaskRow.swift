import SwiftUI

struct WatchTaskRow: View {
    @Bindable var store: WatchStore
    let task: VikunjaTask

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.complete(task) }
            } label: {
                Image(systemName: "circle").font(.title3)
            }
            .buttonStyle(.plain)
            Text(task.title).font(.body).lineLimit(2)
        }
    }
}
