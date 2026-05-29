#if os(macOS)
import AppKit
import SwiftUI
import Carbon

extension Notification.Name {
    static let vikunjaHotkeyChanged = Notification.Name("net.angstreich.VikunjaWidgetApp.hotkeyChanged")
}

// MARK: - SwiftUI wrapper

struct HotkeyRecorderView: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32

    var body: some View {
        HotkeyRecorderRepresentable(keyCode: $keyCode, modifiers: $modifiers)
            .frame(height: 28)
    }
}

// MARK: - Coordinator (file-private so RecorderNSView can reference it)

fileprivate final class HotkeyCoordinator {
    var keyCode: Binding<UInt32>
    var modifiers: Binding<UInt32>
    init(keyCode: Binding<UInt32>, modifiers: Binding<UInt32>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

// MARK: - NSViewRepresentable

private struct HotkeyRecorderRepresentable: NSViewRepresentable {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32

    func makeCoordinator() -> HotkeyCoordinator {
        HotkeyCoordinator(keyCode: $keyCode, modifiers: $modifiers)
    }

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.coordinator = context.coordinator
        view.updateDisplay(keyCode: keyCode, modifiers: modifiers)
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.updateDisplay(keyCode: keyCode, modifiers: modifiers)
    }
}

// MARK: - NSView

fileprivate final class RecorderNSView: NSView {
    weak var coordinator: HotkeyCoordinator?
    private var isRecording = false
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        applyStyle()

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    private func applyStyle() {
        layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.08)
            : NSColor.controlBackgroundColor
        ).cgColor
    }

    func updateDisplay(keyCode: UInt32, modifiers: UInt32) {
        guard !isRecording else { return }
        label.stringValue = hotkeyString(keyCode: keyCode, modifiers: modifiers)
        label.textColor = .labelColor
    }

    // MARK: - Interaction

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording { cancelRecording() } else { startRecording() }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            cancelRecording()
            return
        }
        let nsFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbonMods = toCarbonModifiers(nsFlags)
        let isFKey = Int(event.keyCode) >= kVK_F1 && Int(event.keyCode) <= kVK_F12
        guard carbonMods != 0 || isFKey else { return }
        coordinator?.keyCode.wrappedValue = UInt32(event.keyCode)
        coordinator?.modifiers.wrappedValue = carbonMods
        finishRecording()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        let mods = toCarbonModifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        label.stringValue = modifierString(mods) + "…"
    }

    private func startRecording() {
        isRecording = true
        applyStyle()
        label.stringValue = "Type shortcut…"
        label.textColor = .secondaryLabelColor
        window?.makeFirstResponder(self)
    }

    private func finishRecording() {
        isRecording = false
        applyStyle()
        if let kc = coordinator?.keyCode.wrappedValue,
           let mods = coordinator?.modifiers.wrappedValue {
            label.stringValue = hotkeyString(keyCode: kc, modifiers: mods)
        }
        label.textColor = .labelColor
    }

    private func cancelRecording() {
        isRecording = false
        applyStyle()
        if let kc = coordinator?.keyCode.wrappedValue,
           let mods = coordinator?.modifiers.wrappedValue {
            label.stringValue = hotkeyString(keyCode: kc, modifiers: mods)
        }
        label.textColor = .labelColor
    }
}

// MARK: - Hotkey display helpers

private func toCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if flags.contains(.control) { mods |= UInt32(controlKey) }
    if flags.contains(.option)  { mods |= UInt32(optionKey) }
    if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
    if flags.contains(.command) { mods |= UInt32(cmdKey) }
    return mods
}

private func modifierString(_ carbonMods: UInt32) -> String {
    var s = ""
    if carbonMods & UInt32(controlKey) != 0 { s += "⌃" }
    if carbonMods & UInt32(optionKey)  != 0 { s += "⌥" }
    if carbonMods & UInt32(shiftKey)   != 0 { s += "⇧" }
    if carbonMods & UInt32(cmdKey)     != 0 { s += "⌘" }
    return s
}

func hotkeyString(keyCode: UInt32, modifiers: UInt32) -> String {
    modifierString(modifiers) + keyDisplayName(keyCode)
}

private func keyDisplayName(_ keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_Space:      return "Space"
    case kVK_Return:     return "Return"
    case kVK_Tab:        return "Tab"
    case kVK_Delete:     return "⌫"
    case kVK_Escape:     return "Esc"
    case kVK_UpArrow:    return "↑"
    case kVK_DownArrow:  return "↓"
    case kVK_LeftArrow:  return "←"
    case kVK_RightArrow: return "→"
    case kVK_F1:  return "F1";  case kVK_F2:  return "F2";  case kVK_F3:  return "F3"
    case kVK_F4:  return "F4";  case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
    case kVK_F7:  return "F7";  case kVK_F8:  return "F8";  case kVK_F9:  return "F9"
    case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
    // Letter keys (US QWERTY virtual key codes)
    case 0x00: return "A"; case 0x0B: return "B"; case 0x08: return "C"; case 0x02: return "D"
    case 0x0E: return "E"; case 0x03: return "F"; case 0x05: return "G"; case 0x04: return "H"
    case 0x22: return "I"; case 0x26: return "J"; case 0x28: return "K"; case 0x25: return "L"
    case 0x2E: return "M"; case 0x2D: return "N"; case 0x1F: return "O"; case 0x23: return "P"
    case 0x0C: return "Q"; case 0x0F: return "R"; case 0x01: return "S"; case 0x11: return "T"
    case 0x20: return "U"; case 0x09: return "V"; case 0x0D: return "W"; case 0x07: return "X"
    case 0x10: return "Y"; case 0x06: return "Z"
    // Number keys
    case 0x12: return "1"; case 0x13: return "2"; case 0x14: return "3"; case 0x15: return "4"
    case 0x17: return "5"; case 0x16: return "6"; case 0x1A: return "7"; case 0x1C: return "8"
    case 0x19: return "9"; case 0x1D: return "0"
    default: return "Key\(keyCode)"
    }
}
#endif
