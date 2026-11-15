/// The line number column, as Vim's `number` and `relativenumber` options
/// set it.
public enum VimLineNumbers: Sendable, Hashable, CaseIterable {
    /// No numbers (`:set nonu nornu`).
    case off
    /// Each line's number (`:set nu`).
    case absolute
    /// Distance from the cursor line, which shows 0 (`:set rnu`).
    case relative
    /// Distances, with the cursor line's own number (`:set nu rnu`).
    case hybrid

    init(number: Bool, relative: Bool) {
        self = number ? (relative ? .hybrid : .absolute) : (relative ? .relative : .off)
    }

    var showsNumber: Bool { self == .absolute || self == .hybrid }
    var showsRelative: Bool { self == .relative || self == .hybrid }
}
