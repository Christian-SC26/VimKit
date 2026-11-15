#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import VimCore

extension NSAttributedString.Key {
    /// Marks text as a string literal or a comment, so that `%` and `=` skip
    /// brackets inside it. Set it while highlighting syntax, to a
    /// ``VimTokenType`` or its raw value (`"string"`, `"comment"`).
    public static let vimTokenType = NSAttributedString.Key("VimKitTokenType")
}

extension VimTokenType {
    /// The `.vimTokenType` attribute at `offset`.
    static func at(_ offset: Int, in text: NSAttributedString?) -> VimTokenType? {
        guard let text, offset >= 0, offset < text.length,
              let value = text.attribute(.vimTokenType, at: offset, effectiveRange: nil)
        else { return nil }
        if let type = value as? VimTokenType { return type }
        return (value as? String).flatMap(VimTokenType.init(rawValue:))
    }
}
