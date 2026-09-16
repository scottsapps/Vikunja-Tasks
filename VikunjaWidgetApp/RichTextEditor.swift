import SwiftUI

#if os(macOS)
import AppKit

struct RichTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    var richContext: RichTextContext
    /// Fires only for edits the user actually made. `textDidChange` can't be used
    /// for this: automatic link detection fires it once on load, before anyone has
    /// touched the note.
    var onUserEdit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(binding: $attributedText)
        c.onUserEdit = onUserEdit
        richContext.toggleAction = { [weak c] action in c?.perform(action) }
        return c
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.font = .systemFont(ofSize: 13)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        if attributedText.length > 0 {
            context.coordinator.withProgrammaticUpdate {
                textView.textStorage?.setAttributedString(attributedText)
            }
        }
        // Apply after setting attributedText — setting it before gets overridden.
        textView.textColor = .labelColor
        scrollView.drawsBackground = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard !context.coordinator.isEditing,
              let textView = scrollView.documentView as? NSTextView,
              !textView.attributedString().isEqual(to: attributedText) else { return }
        let coordinator = context.coordinator
        coordinator.withProgrammaticUpdate {
            textView.textStorage?.setAttributedString(attributedText)
            // Re-apply after every attributedText update so dark mode stays correct.
            textView.textColor = .labelColor
        }
        guard textView.isAutomaticLinkDetectionEnabled else { return }
        coordinator.detectLinks(in: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<NSAttributedString>
        var onUserEdit: (() -> Void)?
        weak var textView: NSTextView?
        var isEditing = false
        /// Last selection captured before focus may have left the text view.
        var lastKnownSelection: NSRange = NSRange(location: NSNotFound, length: 0)

        init(binding: Binding<NSAttributedString>) {
            self.binding = binding
        }

        /// NSTextView.checkTextInDocument(_:) does this same detection but blocks the
        /// calling thread on a lower-QoS system service — a priority inversion when
        /// called from the (often user-interactive) main thread, flagged by Xcode 27's
        /// Thread Performance Checker. Running NSDataDetector ourselves off-thread and
        /// only touching the text view to apply the result avoids the blocking wait.
        private static let linkDetector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue)

        func detectLinks(in textView: NSTextView) {
            guard let detector = Self.linkDetector else { return }
            let string = textView.string
            guard !string.isEmpty else { return }
            let fullRange = NSRange(location: 0, length: (string as NSString).length)
            DispatchQueue.global(qos: .utility).async { [weak self, weak textView] in
                let matches = detector.matches(in: string, options: [], range: fullRange)
                DispatchQueue.main.async {
                    guard let self, let textView, textView.window != nil,
                          !self.isEditing, textView.string == string,
                          let storage = textView.textStorage else { return }
                    self.withProgrammaticUpdate {
                        storage.beginEditing()
                        storage.removeAttribute(.link, range: NSRange(location: 0, length: storage.length))
                        for match in matches {
                            guard let url = match.url else { continue }
                            storage.addAttribute(.link, value: url, range: match.range)
                        }
                        storage.endEditing()
                    }
                }
            }
        }

        /// Set while we push a value into the text view ourselves, so the edits that
        /// causes aren't mistaken for the user's. The callbacks are synchronous, so
        /// bracketing the call is enough.
        private var isApplyingProgrammaticUpdate = false

        func withProgrammaticUpdate(_ body: () -> Void) {
            isApplyingProgrammaticUpdate = true
            body()
            isApplyingProgrammaticUpdate = false
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            if !isApplyingProgrammaticUpdate { onUserEdit?() }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isEditing = true
            binding.wrappedValue = tv.attributedString()
            isEditing = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let sel = tv.selectedRange()
            if sel.location != NSNotFound { lastKnownSelection = sel }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
                return true
            }
            if let str = link as? String, let url = URL(string: str) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }

        func perform(_ action: RichTextContext.Action) {
            guard let tv = textView else { return }
            onUserEdit?()
            switch action {
            case .bold:              toggleFontTrait(.boldFontMask, in: tv)
            case .italic:            toggleFontTrait(.italicFontMask, in: tv)
            case .underline:         toggleUnderlineAttr(in: tv)
            case .bulletList:        toggleBulletList(in: tv)
            case .addLink(let url):  addLink(url, in: tv)
            }
        }

        private func addLink(_ url: URL, in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            // Use saved selection; fall back to current range
            let range = (lastKnownSelection.location != NSNotFound && lastKnownSelection.length > 0)
                ? lastKnownSelection
                : tv.selectedRange()
            storage.beginEditing()
            if range.length > 0 && NSMaxRange(range) <= storage.length {
                // Wrap selected text in a link
                storage.addAttribute(.link, value: url, range: range)
            } else {
                // No selection — insert the URL as linked text at the cursor
                let insertAt = min(range.location == NSNotFound ? 0 : range.location, storage.length)
                let attrs: [NSAttributedString.Key: Any] = [
                    .link: url,
                    .font: NSFont.systemFont(ofSize: 13)
                ]
                let linked = NSMutableAttributedString(string: url.absoluteString, attributes: attrs)
                storage.insert(linked, at: insertAt)
            }
            storage.endEditing()
            tv.didChangeText()
            isEditing = true
            binding.wrappedValue = tv.attributedString()
            isEditing = false
        }

        private func toggleFontTrait(_ trait: NSFontTraitMask, in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let range = tv.selectedRange()
            guard range.length > 0 else { return }

            var allHaveTrait = true
            storage.enumerateAttribute(.font, in: range, options: []) { val, _, _ in
                let font = (val as? NSFont) ?? NSFont.systemFont(ofSize: 13)
                if NSFontManager.shared.traits(of: font).intersection(trait) != trait {
                    allHaveTrait = false
                }
            }
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range, options: []) { val, attrRange, _ in
                let font = (val as? NSFont) ?? NSFont.systemFont(ofSize: 13)
                let converted = allHaveTrait
                    ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                    : NSFontManager.shared.convert(font, toHaveTrait: trait)
                storage.addAttribute(.font, value: converted, range: attrRange)
            }
            storage.endEditing()
            tv.didChangeText()
            isEditing = true
            binding.wrappedValue = tv.attributedString()
            isEditing = false
        }

        private func toggleUnderlineAttr(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let range = tv.selectedRange()
            guard range.length > 0 else { return }

            var allHaveUnderline = true
            storage.enumerateAttribute(.underlineStyle, in: range, options: []) { val, _, _ in
                if val == nil { allHaveUnderline = false }
            }
            storage.beginEditing()
            if allHaveUnderline {
                storage.removeAttribute(.underlineStyle, range: range)
            } else {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            storage.endEditing()
            tv.didChangeText()
            isEditing = true
            binding.wrappedValue = tv.attributedString()
            isEditing = false
        }

        private func toggleBulletList(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let sel = tv.selectedRange()
            let paraRange = (storage.string as NSString).paragraphRange(for: sel)

            var hasList = false
            storage.enumerateAttribute(.paragraphStyle, in: paraRange, options: []) { val, _, _ in
                if let ps = val as? NSParagraphStyle, !ps.textLists.isEmpty { hasList = true }
            }

            storage.beginEditing()
            if hasList {
                storage.enumerateAttribute(.paragraphStyle, in: paraRange, options: []) { val, range, _ in
                    guard let ps = val as? NSParagraphStyle else { return }
                    let mps = ps.mutableCopy() as! NSMutableParagraphStyle
                    mps.textLists = []
                    mps.headIndent = 0
                    mps.firstLineHeadIndent = 0
                    storage.addAttribute(.paragraphStyle, value: mps, range: range)
                }
            } else {
                let list = NSTextList(markerFormat: .disc, options: 0)
                let mps = NSMutableParagraphStyle()
                mps.textLists = [list]
                mps.headIndent = 36
                mps.firstLineHeadIndent = 36
                storage.addAttribute(.paragraphStyle, value: mps, range: paraRange)
            }
            storage.endEditing()
            tv.didChangeText()
            isEditing = true
            binding.wrappedValue = tv.attributedString()
            isEditing = false
        }
    }
}

#elseif os(iOS)
import UIKit

struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    var richContext: RichTextContext
    /// Fires only for edits the user actually made — see the macOS note above.
    var onUserEdit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(binding: $attributedText)
        c.onUserEdit = onUserEdit
        richContext.toggleAction = { [weak c] action in c?.perform(action) }
        return c
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.allowsEditingTextAttributes = true
        tv.font = .systemFont(ofSize: 13)
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        if attributedText.length > 0 {
            context.coordinator.withProgrammaticUpdate { tv.attributedText = attributedText }
        }
        // Apply after setting attributedText — setting it before gets overridden.
        tv.textColor = .label
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        guard !context.coordinator.isEditing,
              !tv.attributedText.isEqual(to: attributedText) else { return }
        context.coordinator.withProgrammaticUpdate {
            tv.attributedText = attributedText
            // Re-apply after every attributedText update so dark mode stays correct.
            tv.textColor = .label
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var binding: Binding<NSAttributedString>
        var onUserEdit: (() -> Void)?
        weak var textView: UITextView?
        var isEditing = false
        /// Last selection captured before focus may have left the text view.
        var lastKnownSelection: NSRange = NSRange(location: NSNotFound, length: 0)

        init(binding: Binding<NSAttributedString>) {
            self.binding = binding
        }

        /// See the macOS coordinator — same guard, so pushing a value into the text
        /// view never registers as the user editing it.
        private var isApplyingProgrammaticUpdate = false

        func withProgrammaticUpdate(_ body: () -> Void) {
            isApplyingProgrammaticUpdate = true
            body()
            isApplyingProgrammaticUpdate = false
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if !isApplyingProgrammaticUpdate { onUserEdit?() }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            isEditing = true
            binding.wrappedValue = textView.attributedText ?? NSAttributedString()
            isEditing = false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let sel = textView.selectedRange
            if sel.location != NSNotFound { lastKnownSelection = sel }
        }

        @available(iOS 17, *)
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content {
                return UIAction { _ in UIApplication.shared.open(url) }
            }
            return defaultAction
        }

        func perform(_ action: RichTextContext.Action) {
            guard let tv = textView else { return }
            onUserEdit?()
            switch action {
            case .bold:              toggleTrait(.traitBold, in: tv)
            case .italic:            toggleTrait(.traitItalic, in: tv)
            case .underline:         toggleUnderlineAttr(in: tv)
            case .bulletList:        toggleBulletList(in: tv)
            case .addLink(let url):  addLink(url, in: tv)
            }
        }

        private func addLink(_ url: URL, in tv: UITextView) {
            let storage = tv.textStorage
            let range = (lastKnownSelection.location != NSNotFound && lastKnownSelection.length > 0)
                ? lastKnownSelection
                : tv.selectedRange
            storage.beginEditing()
            if range.length > 0 && NSMaxRange(range) <= storage.length {
                storage.addAttribute(.link, value: url, range: range)
            } else {
                let insertAt = min(range.location == NSNotFound ? 0 : range.location, storage.length)
                let attrs: [NSAttributedString.Key: Any] = [
                    .link: url,
                    .font: UIFont.systemFont(ofSize: 13)
                ]
                let linked = NSMutableAttributedString(string: url.absoluteString, attributes: attrs)
                storage.insert(linked, at: insertAt)
            }
            storage.endEditing()
            isEditing = true
            binding.wrappedValue = tv.attributedText ?? NSAttributedString()
            isEditing = false
        }

        private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits, in tv: UITextView) {
            let range = tv.selectedRange
            guard range.length > 0 else { return }
            let storage = tv.textStorage
            var allHaveTrait = true
            storage.enumerateAttribute(.font, in: range, options: []) { val, _, _ in
                let font = (val as? UIFont) ?? UIFont.systemFont(ofSize: 13)
                if !font.fontDescriptor.symbolicTraits.contains(trait) { allHaveTrait = false }
            }
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range, options: []) { val, attrRange, _ in
                let font = (val as? UIFont) ?? UIFont.systemFont(ofSize: 13)
                var traits = font.fontDescriptor.symbolicTraits
                if allHaveTrait { traits.remove(trait) } else { traits.insert(trait) }
                if let desc = font.fontDescriptor.withSymbolicTraits(traits) {
                    storage.addAttribute(.font, value: UIFont(descriptor: desc, size: 0), range: attrRange)
                }
            }
            storage.endEditing()
            isEditing = true
            binding.wrappedValue = tv.attributedText ?? NSAttributedString()
            isEditing = false
        }

        private func toggleUnderlineAttr(in tv: UITextView) {
            let range = tv.selectedRange
            guard range.length > 0 else { return }
            let storage = tv.textStorage
            var allHaveUnderline = true
            storage.enumerateAttribute(.underlineStyle, in: range, options: []) { val, _, _ in
                if val == nil { allHaveUnderline = false }
            }
            storage.beginEditing()
            if allHaveUnderline {
                storage.removeAttribute(.underlineStyle, range: range)
            } else {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            storage.endEditing()
            isEditing = true
            binding.wrappedValue = tv.attributedText ?? NSAttributedString()
            isEditing = false
        }

        private func toggleBulletList(in tv: UITextView) {
            let storage = tv.textStorage
            let sel = tv.selectedRange
            let paraRange = (storage.string as NSString).paragraphRange(for: sel)

            var hasList = false
            storage.enumerateAttribute(.paragraphStyle, in: paraRange, options: []) { val, _, _ in
                if let ps = val as? NSParagraphStyle, !ps.textLists.isEmpty { hasList = true }
            }

            storage.beginEditing()
            if hasList {
                storage.enumerateAttribute(.paragraphStyle, in: paraRange, options: []) { val, range, _ in
                    guard let ps = val as? NSParagraphStyle else { return }
                    let mps = ps.mutableCopy() as! NSMutableParagraphStyle
                    mps.textLists = []
                    mps.headIndent = 0
                    mps.firstLineHeadIndent = 0
                    storage.addAttribute(.paragraphStyle, value: mps, range: range)
                }
            } else {
                let list = NSTextList(markerFormat: .disc, options: 0)
                let mps = NSMutableParagraphStyle()
                mps.textLists = [list]
                mps.headIndent = 36
                mps.firstLineHeadIndent = 36
                storage.addAttribute(.paragraphStyle, value: mps, range: paraRange)
            }
            storage.endEditing()
            isEditing = true
            binding.wrappedValue = tv.attributedText ?? NSAttributedString()
            isEditing = false
        }
    }
}
#endif
