import AppKit
@testable import VimCore
@testable import VimKit

/// A VimTextView inside a scroll view inside an (unshown) window, laid out
/// like a real editor so geometry and scrolling behave as on screen.
@MainActor
final class EditorWindow {
    let window: NSWindow
    let scrollView: NSScrollView
    let view: VimTextView

    init(text: String, size: NSSize = NSSize(width: 800, height: 600), wraps: Bool = true, fontSize: CGFloat = 13) {
        let runtime = VimRuntime()
        runtime.clipboard = InMemoryClipboard()
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wraps
        view = VimTextView(frame: NSRect(origin: .zero, size: size), options: VimOptions(), runtime: runtime)
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: 0, height: size.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        if wraps {
            view.textContainer?.widthTracksTextView = true
        } else {
            view.isHorizontallyResizable = true
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        scrollView.documentView = view
        window.contentView = scrollView
        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(view)
        window.layoutIfNeeded()
    }

    /// Visible text rows (top and bottom line numbers are approximate to a row).
    var visibleRect: NSRect { scrollView.contentView.bounds }

    /// Types keys in Vim notation (`dd`, `<Esc>`, `<C-d>`, `<CR>`, `<lt>`) through `keyDown`.
    func type(_ keys: String) {
        for event in Self.events(keys) { view.keyDown(with: event) }
    }

    static func events(_ keys: String) -> [NSEvent] {
        var result: [NSEvent] = []
        var index = keys.startIndex
        while index < keys.endIndex {
            if keys[index] == "<", let close = keys[index...].firstIndex(of: ">"), close > keys.index(after: index) {
                let name = String(keys[keys.index(after: index)..<close])
                if let event = special(name) {
                    result.append(event)
                    index = keys.index(after: close)
                    continue
                }
            }
            result.append(character(keys[index], modifiers: []))
            index = keys.index(after: index)
        }
        return result
    }

    private static let keyCodes: [Character: (UInt16, Bool)] = {
        var map: [Character: (UInt16, Bool)] = [:]
        for (code, pair) in VimKeyEvent.usLayout {
            map[pair.0] = (code, false)
            if map[pair.1] == nil { map[pair.1] = (code, true) }
        }
        map[" "] = (49, false)
        return map
    }()

    private static func character(_ c: Character, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        let (code, shifted) = keyCodes[c] ?? (0, false)
        var flags = modifiers
        if shifted { flags.insert(.shift) }
        var characters = String(c)
        if modifiers.contains(.control), let ascii = c.asciiValue, c.isLetter {
            characters = String(UnicodeScalar(ascii & 0x1F))
        }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                context: nil, characters: characters, charactersIgnoringModifiers: String(c),
                                isARepeat: false, keyCode: code)!
    }

    private static func special(_ name: String) -> NSEvent? {
        let named: [String: (String, UInt16)] = [
            "Esc": ("\u{1b}", 53), "CR": ("\r", 36), "BS": ("\u{7f}", 51), "Tab": ("\t", 48),
            "Space": (" ", 49), "lt": ("<", 43),
        ]
        if name == "lt" { return character("<", modifiers: []) }
        if let (chars, code) = named[name] {
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                    context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                    isARepeat: false, keyCode: code)
        }
        if name.hasPrefix("C-"), name.count == 3, let c = name.last {
            return character(c, modifiers: .control)
        }
        return nil
    }
}

/// About 70 characters per line of code-like text.
func sampleCode(lines: Int) -> String {
    (0..<lines).map { i in
        i % 10 == 9 ? "" : "    let value\(i) = compute(\(i), \"label \(i)\") // note \(i % 97)"
    }.joined(separator: "\n")
}
