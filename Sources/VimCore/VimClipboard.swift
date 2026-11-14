#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Backing store for Vim's `+` and `*` registers.
@MainActor
public protocol VimClipboard: AnyObject {
    var string: String? { get set }
}

/// The system pasteboard.
@MainActor
public final class SystemClipboard: VimClipboard {
    public init() {}

    public var string: String? {
        get {
            #if canImport(AppKit)
            NSPasteboard.general.string(forType: .string)
            #elseif canImport(UIKit)
            UIPasteboard.general.string
            #else
            nil
            #endif
        }
        set {
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
            #elseif canImport(UIKit)
            UIPasteboard.general.string = newValue
            #endif
        }
    }
}

/// A clipboard that lives in memory, for tests and sandboxed hosts.
@MainActor
public final class InMemoryClipboard: VimClipboard {
    public var string: String?
    public init(_ string: String? = nil) { self.string = string }
}
