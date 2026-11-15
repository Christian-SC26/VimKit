/// A key press, described the way a DOM `KeyboardEvent` would describe it,
/// which is what the vim engine understands.
public struct VimKeyEvent: Sendable, Hashable {
    /// The produced character (`"a"`, `"D"`, `"д"`) or a key name
    /// such as ``escape``, ``enter`` or ``arrowLeft``.
    public var key: String
    /// The physical key, e.g. `KeyJ`. Vim uses it to keep normal-mode
    /// commands working on non-Latin keyboard layouts.
    public var code: String
    public var control: Bool
    public var option: Bool
    public var command: Bool
    public var shift: Bool

    public init(
        key: String,
        code: String = "",
        control: Bool = false,
        option: Bool = false,
        command: Bool = false,
        shift: Bool = false
    ) {
        self.key = key
        self.code = code
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
    }

    // Key names (DOM `KeyboardEvent.key` values).
    public static let escape = "Escape"
    public static let enter = "Enter"
    public static let backspace = "Backspace"
    public static let delete = "Delete"
    public static let tab = "Tab"
    public static let arrowLeft = "ArrowLeft"
    public static let arrowRight = "ArrowRight"
    public static let arrowUp = "ArrowUp"
    public static let arrowDown = "ArrowDown"
    public static let home = "Home"
    public static let end = "End"
    public static let pageUp = "PageUp"
    public static let pageDown = "PageDown"

    var jsObject: [String: Any] {
        [
            "key": key,
            "code": code,
            "ctrlKey": control,
            "altKey": option,
            "metaKey": command,
            "shiftKey": shift,
        ]
    }
}

extension VimKeyEvent {
    /// US-ANSI characters for macOS virtual key codes: (unshifted, shifted).
    static let usLayout: [UInt16: (Character, Character)] = [
        0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"), 5: ("g", "G"),
        6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"), 11: ("b", "B"), 12: ("q", "Q"),
        13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"), 16: ("y", "Y"), 17: ("t", "T"),
        18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 22: ("6", "^"), 23: ("5", "%"),
        24: ("=", "+"), 25: ("9", "("), 26: ("7", "&"), 27: ("-", "_"), 28: ("8", "*"), 29: ("0", ")"),
        30: ("]", "}"), 31: ("o", "O"), 32: ("u", "U"), 33: ("[", "{"), 34: ("i", "I"), 35: ("p", "P"),
        37: ("l", "L"), 38: ("j", "J"), 39: ("'", "\""), 40: ("k", "K"), 41: (";", ":"), 42: ("\\", "|"),
        43: (",", "<"), 44: ("/", "?"), 45: ("n", "N"), 46: ("m", "M"), 47: (".", ">"), 50: ("`", "~"),
    ]

    /// The `code` for a macOS virtual key code.
    ///
    /// Vim reads the last character of `code` (lower-cased unless Shift is
    /// held) when a non-Latin character arrives, so letters get `KeyX` and
    /// other keys get `Key` followed by the US character they carry.
    public static func physicalCode(forKeyCode keyCode: UInt16, shift: Bool) -> String {
        guard let (plain, shifted) = usLayout[keyCode] else { return "" }
        if plain.isLetter { return "Key" + plain.uppercased() }
        return "Key" + String(shift ? shifted : plain)
    }

    /// Key names for macOS virtual key codes that do not produce text.
    public static let specialKeyCodes: [UInt16: String] = [
        53: escape, 36: enter, 76: enter, 51: backspace, 117: delete, 48: tab,
        123: arrowLeft, 124: arrowRight, 125: arrowDown, 126: arrowUp,
        115: home, 119: end, 116: pageUp, 121: pageDown,
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

// MARK: - HID usages (UIKit `UIKey.keyCode`)

extension VimKeyEvent {
    /// Builds an event from a USB HID keyboard usage, the key code UIKit
    /// reports in `UIKey.keyCode`, and the characters the key produced.
    /// Returns nil for keys vim cannot use (modifier-only presses, unknown
    /// function keys).
    public init?(
        hidUsage: Int,
        characters: String,
        charactersIgnoringModifiers: String,
        control: Bool = false,
        option: Bool = false,
        command: Bool = false,
        shift: Bool = false
    ) {
        let code = Self.physicalCode(forHIDUsage: hidUsage, shift: shift)
        if let special = Self.specialHIDUsages[hidUsage] {
            self.init(key: special, code: code, control: control, option: option, command: command, shift: shift)
            return
        }
        // Same rules as for AppKit: with Control or Command vim wants the plain key.
        let produced = control || command ? charactersIgnoringModifiers : characters
        guard let scalar = produced.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        if (0xF700...0xF8FF).contains(scalar.value) || produced.hasPrefix("UIKeyInput") { return nil }
        self.init(key: produced, code: code, control: control, option: option, command: command, shift: shift)
    }

    /// US-ANSI characters for HID keyboard usages: (unshifted, shifted).
    static let usLayoutHID: [Int: (Character, Character)] = {
        var map: [Int: (Character, Character)] = [:]
        for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[4 + index] = (letter, Character(letter.uppercased()))
        }
        for (index, pair) in zip("1234567890", "!@#$%^&*()").enumerated() {
            map[30 + index] = pair
        }
        let punctuation: [Int: (Character, Character)] = [
            45: ("-", "_"), 46: ("=", "+"), 47: ("[", "{"), 48: ("]", "}"), 49: ("\\", "|"),
            51: (";", ":"), 52: ("'", "\""), 53: ("`", "~"), 54: (",", "<"), 55: (".", ">"), 56: ("/", "?"),
        ]
        map.merge(punctuation) { $1 }
        return map
    }()

    /// The `code` for a HID keyboard usage (see ``physicalCode(forKeyCode:shift:)``).
    public static func physicalCode(forHIDUsage usage: Int, shift: Bool) -> String {
        guard let (plain, shifted) = usLayoutHID[usage] else { return "" }
        if plain.isLetter { return "Key" + plain.uppercased() }
        return "Key" + String(shift ? shifted : plain)
    }

    /// Key names for HID keyboard usages that do not produce text.
    public static let specialHIDUsages: [Int: String] = {
        var map: [Int: String] = [
            41: escape, 40: enter, 88: enter, 42: backspace, 76: delete, 43: tab,
            80: arrowLeft, 79: arrowRight, 81: arrowDown, 82: arrowUp,
            74: home, 77: end, 75: pageUp, 78: pageDown,
        ]
        for index in 0..<12 { map[58 + index] = "F\(index + 1)" }
        return map
    }()
}
