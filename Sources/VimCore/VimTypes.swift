import Foundation

/// The editing mode Vim is in.
public enum VimMode: String, Sendable, Hashable {
    case normal
    case insert
    case replace
    case visual
    case visualLine
    case visualBlock

    /// True for the modes where text is typed into the document.
    public var isInsertLike: Bool { self == .insert || self == .replace }

    /// True for the three visual modes.
    public var isVisual: Bool { self == .visual || self == .visualLine || self == .visualBlock }

    /// The label Vim shows in the status line, e.g. `-- INSERT --`.
    public var label: String {
        switch self {
        case .normal: ""
        case .insert: "-- INSERT --"
        case .replace: "-- REPLACE --"
        case .visual: "-- VISUAL --"
        case .visualLine: "-- VISUAL LINE --"
        case .visualBlock: "-- VISUAL BLOCK --"
        }
    }
}

/// The `:` or `/` command line while the user is typing into it.
public struct VimCommandLine: Sendable, Hashable, Codable {
    /// The prompt, e.g. `:` or `/`.
    public var prefix: String
    /// The text typed so far.
    public var text: String
    /// Caret position inside `text`, in UTF-16 code units.
    public var cursor: Int
    /// Extra hint vim shows next to the prompt (may be empty).
    public var description: String
}

/// Everything a status line needs to show.
public struct VimStatus: Sendable, Hashable {
    public var mode: VimMode = .normal
    /// Keys of a command still being typed, e.g. `2d`.
    public var pendingKeys: String = ""
    /// True while running one normal-mode command from insert mode (`<C-o>`).
    public var isInsertModeReturn: Bool = false
    /// UTF-16 offset of the Vim cursor (the block cursor in normal/visual mode).
    public var cursorOffset: Int = 0
    /// Non-nil while the `:` or `/` prompt is open.
    public var commandLine: VimCommandLine?
    /// Persistent notice such as `recording @q`.
    public var banner: String?
    /// Last message from vim, e.g. an error from an ex command.
    public var message: String?
    public var messageIsError: Bool = false

    public init() {}
}

/// One selection range. `anchor == head` is a caret. Offsets are UTF-16 code units.
public struct VimSelection: Sendable, Hashable {
    public var anchor: Int
    public var head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    public init(_ range: NSRange) {
        self.init(anchor: range.location, head: range.location + range.length)
    }

    public var range: NSRange {
        NSRange(location: min(anchor, head), length: abs(head - anchor))
    }
}

/// A line/column position (both zero-based, column in UTF-16 code units).
public struct VimPosition: Sendable, Hashable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "(\(line), \(column))" }
}

/// An ex command defined with ``VimEngine/defineEx(_:prefix:handler:)``.
public struct VimExCommand: Sendable, Hashable, Decodable {
    public var name: String
    /// Everything after the command name, e.g. `foo bar` for `:cmd foo bar`.
    public var argString: String
    /// `argString` split on whitespace.
    public var args: [String]
    /// First line of the range (zero-based), if one was given.
    public var line: Int?
    /// Last line of the range (zero-based), if one was given.
    public var lineEnd: Int?
}

/// Scroll geometry of the hosting view, in its content coordinates.
public struct VimScrollInfo: Sendable, Hashable {
    public var visibleRect: CGRect
    public var contentSize: CGSize

    public init(visibleRect: CGRect, contentSize: CGSize) {
        self.visibleRect = visibleRect
        self.contentSize = contentSize
    }
}

/// Per-editor settings.
public struct VimOptions: Sendable, Hashable {
    public var tabSize: Int = 4
    /// Columns added or removed by `>>` and `<<`.
    public var shiftWidth: Int = 4
    /// Insert spaces instead of tab characters when indenting.
    public var expandTab: Bool = true
    /// Token used by `gc` to comment lines, e.g. `//`. `nil` disables it.
    public var lineComment: String?
    public var isReadOnly: Bool = false

    public init(
        tabSize: Int = 4,
        shiftWidth: Int = 4,
        expandTab: Bool = true,
        lineComment: String? = nil,
        isReadOnly: Bool = false
    ) {
        self.tabSize = tabSize
        self.shiftWidth = shiftWidth
        self.expandTab = expandTab
        self.lineComment = lineComment
        self.isReadOnly = isReadOnly
    }

    var jsObject: [String: Any] {
        var object: [String: Any] = [
            "tabSize": tabSize,
            "indentUnit": shiftWidth,
            "indentWithTabs": !expandTab,
            "readOnly": isReadOnly,
        ]
        if let lineComment { object["lineComment"] = lineComment }
        return object
    }
}

/// Syntax category of a position, used by `%` and quote text objects to
/// skip brackets and quotes inside strings and comments.
public enum VimTokenType: String, Sendable {
    case string, comment
}

/// A closed fold: lines the view should hide (`zc`, `zM`, `zf`...).
public struct VimFold: Equatable, Sendable {
    /// The hidden lines, from the start of the first one to the start of the
    /// line after the last (or the end of the text). The fold's header line,
    /// which stays visible, ends just before it.
    public var hiddenRange: NSRange
    /// Number of hidden lines.
    public var lineCount: Int

    public init(hiddenRange: NSRange, lineCount: Int) {
        self.hiddenRange = hiddenRange
        self.lineCount = lineCount
    }
}

/// Mode a mapping applies to.
public enum VimMapMode: String, Sendable {
    case normal, insert, visual
}

/// The contents of a register.
public struct VimRegister: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Pasted inside a line, like `yiw`.
        case characterwise
        /// Whole lines, like `yy`; the text ends with a newline.
        case linewise
        /// A rectangle, like a `<C-v>` selection.
        case blockwise
    }

    public var text: String
    public var kind: Kind

    public init(text: String, kind: Kind = .characterwise) {
        self.text = text
        self.kind = kind
    }
}

public enum VimLogLevel: Int, Sendable, Comparable {
    case debug, info, warning, error

    init(jsLevel: String) {
        switch jsLevel {
        case "debug": self = .debug
        case "warn": self = .warning
        case "error": self = .error
        default: self = .info
        }
    }

    public static func < (lhs: VimLogLevel, rhs: VimLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}
