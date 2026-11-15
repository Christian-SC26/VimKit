#if canImport(UIKit) && !os(watchOS)
import UIKit
import VimCore

extension VimKeyEvent {
    /// Converts a UIKit hardware key. Returns nil for keys vim cannot use
    /// (modifier-only presses, unknown function keys).
    @MainActor
    public init?(_ key: UIKey) {
        let flags = key.modifierFlags
        self.init(
            hidUsage: key.keyCode.rawValue,
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            control: flags.contains(.control),
            option: flags.contains(.alternate),
            command: flags.contains(.command),
            shift: flags.contains(.shift)
        )
    }
}
#endif
