import SwiftUI

struct RichTextToolbar: View {
    var richContext: RichTextContext

    var body: some View {
        HStack(spacing: 0) {
            toolbarButton("bold", action: .bold)
            toolbarButton("italic", action: .italic)
            toolbarButton("underline", action: .underline)
            Divider().frame(height: 14).padding(.horizontal, 4)
            toolbarButton("list.bullet", action: .bulletList)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func toolbarButton(_ icon: String, action: RichTextContext.Action) -> some View {
        Button {
            richContext.perform(action)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
