#if os(macOS)
import AppKit
import VimCore

extension VimKeyEvent {
    /// Converts an AppKit key-down event. Returns nil for events vim cannot
    /// use (modifier-only presses, unknown function keys).
    public init?(_ event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let code = Self.physicalCode(forKeyCode: event.keyCode, shift: shift)

        if let special = Self.specialKeyCodes[event.keyCode] {
            self.init(key: special, code: code, control: control, option: option, command: command, shift: shift)
            return
        }
        // With Control or Command the produced character is a control code
        // or irrelevant; vim wants the plain key. Option keeps the composed
        // character (on many layouts Option produces brackets and braces).
        let characters = control || command ? event.charactersIgnoringModifiers : event.characters
        guard let characters, let scalar = characters.unicodeScalars.first else { return nil }
        // Function and navigation keys arrive as private-use characters.
        if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        self.init(key: characters, code: code, control: control, option: option, command: command, shift: shift)
    }
}
#endif
