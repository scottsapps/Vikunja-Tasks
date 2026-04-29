import Foundation

@Observable
final class RichTextContext {
    enum Action { case bold, italic, underline, bulletList }
    var toggleAction: ((Action) -> Void)?

    func perform(_ action: Action) {
        toggleAction?(action)
    }
}
