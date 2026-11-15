#if os(macOS)
import AppKit
import VimCore
import VimKit

enum Level: String, Codable, CaseIterable, Sendable {
    /// `VimEngine` alone: JavaScriptCore + the vim.js adapter, no UI.
    case engine
    /// `VimTextView` in an offscreen window: key event → engine → TextKit 2 → display.
    case view
}

/// A document the bench can type into, at one of the two levels.
@MainActor
protocol BenchDocument: AnyObject {
    /// Returns a closure that plays `keys`, parsed once up front so parsing
    /// is not measured.
    func player(_ keys: String) -> @MainActor () -> Void
    /// The text view and the engine hold the same text.
    var inSync: Bool { get }
    func close()
}

extension BenchDocument {
    func type(_ keys: String) { player(keys)() }
}

@MainActor
final class EngineDocument: BenchDocument {
    let engine: VimEngine

    init(text: String, runtime: VimRuntime) {
        engine = VimEngine(text: text, runtime: runtime)
    }

    func player(_ keys: String) -> @MainActor () -> Void {
        let engine = engine
        if keys.isEmpty { return {} }
        return { engine.feed(keys) }
    }

    var inSync: Bool { true }
    func close() {}
}

/// A VimTextView inside a scroll view inside an unshown window, sized like a
/// real editor so layout, scrolling and screen motions behave as on screen.
@MainActor
final class ViewDocument: BenchDocument {
    let window: NSWindow
    let scrollView: NSScrollView
    let view: VimTextView

    init(text: String, runtime: VimRuntime, size: NSSize = NSSize(width: 900, height: 700)) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        view = VimTextView(frame: NSRect(origin: .zero, size: size), options: VimOptions(), runtime: runtime)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: 0, height: size.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scrollView.documentView = view
        window.contentView = scrollView
        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(view)
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    func player(_ keys: String) -> @MainActor () -> Void {
        let events = KeyEvents.parse(keys)
        let view = view, window = window
        return {
            for event in events { view.keyDown(with: event) }
            // Include the layout and drawing the keys caused, as on screen.
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    var inSync: Bool { view.string == view.vim.text }

    func close() { window.close() }
}

/// Builds AppKit key events from Vim notation (`dd`, `<Esc>`, `<C-d>`, `<CR>`, `<lt>`)
/// with US-layout key codes, as a hardware keyboard would send them.
enum KeyEvents {
    static func parse(_ keys: String) -> [NSEvent] {
        var result: [NSEvent] = []
        var index = keys.startIndex
        while index < keys.endIndex {
            if keys[index] == "<", let close = keys[index...].firstIndex(of: ">"), close > keys.index(after: index),
               let event = special(String(keys[keys.index(after: index)..<close])) {
                result.append(event)
                index = keys.index(after: close)
                continue
            }
            result.append(character(keys[index], modifiers: []))
            index = keys.index(after: index)
        }
        return result
    }

    private static let keyCodes: [Character: (UInt16, Bool)] = {
        let plain: [(String, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
            ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
            ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
            ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47),
            ("`", 50), (" ", 49),
        ]
        let shifted: [Character: Character] = [
            "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
            "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
            "`": "~",
        ]
        var map: [Character: (UInt16, Bool)] = [:]
        for (string, code) in plain {
            let c = Character(string)
            map[c] = (code, false)
            if c.isLetter { map[Character(c.uppercased())] = (code, true) }
            if let s = shifted[c] { map[s] = (code, true) }
        }
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
            "Esc": ("\u{1b}", 53), "CR": ("\r", 36), "BS": ("\u{7f}", 51), "Tab": ("\t", 48), "Space": (" ", 49),
        ]
        if name == "lt" { return character("<", modifiers: []) }
        if let (characters, code) = named[name] {
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)
        }
        if name.hasPrefix("C-"), name.count == 3, let c = name.last {
            return character(c, modifiers: .control)
        }
        return nil
    }
}
#endif
