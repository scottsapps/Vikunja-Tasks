import SwiftUI

struct RichTextToolbar: View {
    var richContext: RichTextContext

    @State private var showLinkInput = false
    @State private var linkURLString = ""

    var body: some View {
        HStack(spacing: 0) {
            toolbarButton("bold", action: .bold)
            toolbarButton("italic", action: .italic)
            toolbarButton("underline", action: .underline)
            Divider().frame(height: 14).padding(.horizontal, 4)
            toolbarButton("list.bullet", action: .bulletList)
            Divider().frame(height: 14).padding(.horizontal, 4)
            Button {
                showLinkInput = true
            } label: {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add Link")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .alert("Add Link", isPresented: $showLinkInput) {
            TextField("https://example.com", text: $linkURLString)
                #if os(iOS)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            Button("Add") {
                var raw = linkURLString.trimmingCharacters(in: .whitespaces)
                if !raw.isEmpty {
                    if !raw.contains("://") { raw = "https://\(raw)" }
                    if let url = URL(string: raw) {
                        richContext.perform(.addLink(url: url))
                    }
                }
                linkURLString = ""
            }
            Button("Cancel", role: .cancel) { linkURLString = "" }
        } message: {
            Text("Paste or type a URL. Selected text will become the link; otherwise the URL is inserted.")
        }
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
