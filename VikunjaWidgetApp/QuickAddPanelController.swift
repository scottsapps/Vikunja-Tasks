#if os(macOS)
import AppKit
import SwiftUI
import Carbon

// MARK: - Custom panel

// NSWindow.canBecomeKey returns false for borderless windows by default,
// which prevents text fields from receiving keyboard input.
private final class QuickAddPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Panel controller

final class QuickAddPanelController: NSObject {

    private var panel: NSPanel?
    private weak var store: TaskStore?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // MARK: - Setup

    func setup(store: TaskStore) {
        guard self.store == nil else { return }
        self.store = store
        buildPanel()
        registerHotKey()
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let p = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.center()
        panel = p
    }

    // MARK: - Show / toggle

    func toggle() {
        guard let panel else { return }
        if panel.isVisible {
            panel.close()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let panel, let store else { return }
        // Recreate content on each open so @State (inputText, etc.) resets
        let ctrl = NSHostingController(rootView: QuickAddPanelContent(store: store))
        ctrl.view.wantsLayer = true
        ctrl.view.layer?.backgroundColor = .clear
        panel.contentViewController = ctrl
        panel.setContentSize(NSSize(width: 500, height: 220))
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's @FocusState fires asynchronously on .onAppear; nudge AppKit
        // directly on the next run loop pass to guarantee the cursor lands in the field.
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            panel.makeFirstResponder(panel.contentView?.nextValidKeyView)
        }
    }

    // MARK: - Global hotkey (Ctrl+Space)

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("VKQA"), id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let ptr = userData else { return OSStatus(eventNotHandledErr) }
                let ctrl = Unmanaged<QuickAddPanelController>.fromOpaque(ptr).takeUnretainedValue()
                DispatchQueue.main.async { ctrl.toggle() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
    }
}

// MARK: - SwiftUI content for the panel

private struct QuickAddPanelContent: View {
    var store: TaskStore

    var body: some View {
        QuickAddSheet(store: store)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Helpers

private func fourCharCode(_ s: String) -> FourCharCode {
    s.utf8.reduce(0) { $0 << 8 + FourCharCode($1) }
}

#endif
