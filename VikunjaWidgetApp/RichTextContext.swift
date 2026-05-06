import Foundation

@Observable
final class RichTextContext {
    enum Action { case bold, italic, underline, bulletList, addLink(url: URL) }
    var toggleAction: ((Action) -> Void)?

    func perform(_ action: Action) {
        toggleAction?(action)
    }
}
