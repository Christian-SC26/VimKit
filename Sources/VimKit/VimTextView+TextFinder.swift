#if os(macOS)
import AppKit
import CoreText

/// The system find bar (`NSTextFinder`, ⌘F) for ``VimTextView``.
///
/// `NSTextView` comes with it; a custom view gets it by implementing
/// `NSTextFinderClient`: the finder reads the text, selects and scrolls to
/// matches, asks for the rectangles of characters to highlight them, and
/// asks the view to draw the characters inside the yellow indicator.
extension VimTextView {
    /// The find bar of this view; it is shown in the enclosing scroll view.
    public var textFinder: NSTextFinder {
        let finder = textFinderStorage ?? {
            let finder = NSTextFinder()
            let client = VimTextFinderClient(view: self)
            textFinderClient = client
            finder.client = client
            finder.isIncrementalSearchingEnabled = true
            finder.incrementalSearchingShouldDimContentView = true
            textFinderStorage = finder
            return finder
        }()
        if finder.findBarContainer !== enclosingScrollView { finder.findBarContainer = enclosingScrollView }
        return finder
    }

    func noteTextWillChange() {
        textFinderStorage?.noteClientStringWillChange()
    }

    /// Edit › Find menu items; their `tag` is an `NSTextFinder.Action`.
    open override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        _ = performFinderAction(NSTextFinder.Action(rawValue: tag) ?? .showFindInterface)
    }

    /// Performs a find bar action if it applies now.
    func performFinderAction(_ action: NSTextFinder.Action) -> Bool {
        withFindSelection(for: action) {
            guard textFinder.validateAction(action) else { return false }
            textFinder.performAction(action)
            return true
        }
    }

    /// "Use Selection for Find" (⌘E) with nothing selected — always so in
    /// Vim's normal mode — uses the word under the cursor, like `*`.
    func withFindSelection<T>(for action: NSTextFinder.Action, _ body: () -> T) -> T {
        guard action == .setSearchString, selectedRange().length == 0, let word = wordUnderCursor else { return body() }
        findSelectionOverride = word
        defer { findSelectionOverride = nil }
        return body()
    }

    /// The word (or run of punctuation) at the cursor, not blanks.
    var wordUnderCursor: NSRange? {
        let offset = isVimEnabled ? vim.status.cursorOffset : selectedRange().location
        guard offset < textStorage.length else { return nil }
        let range = textStorage.doubleClick(at: offset)
        guard range.length > 0,
              textStorage.attributedSubstring(from: range).string.contains(where: { !$0.isWhitespace }) else { return nil }
        return range
    }

    /// The older find panel action; its tags are the same as `NSTextFinder.Action`.
    @objc public func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    func handleFindKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let action: NSTextFinder.Action? = switch (key, flags) {
        case ("f", [.command]): .showFindInterface
        case ("f", [.command, .option]): .showReplaceInterface
        case ("g", [.command]): .nextMatch
        case ("g", [.command, .shift]): .previousMatch
        case ("e", [.command]): .setSearchString
        default: nil
        }
        guard let action else { return false }
        return performFinderAction(action)
    }

    /// Visible lines that `range` touches, each with its top (text coordinates).
    func layoutLines(covering range: NSRange) -> [(line: Int, y: CGFloat)] {
        let first = layout.line(containing: range.location)
        let last = layout.line(containing: max(range.location, range.upperBound))
        return (first...last).compactMap { line in
            layout.visibleRows(ofLine: line) > 0 ? (line, layout.y(ofLine: line)) : nil
        }
    }

    /// One rectangle per screen row of `range`, in view coordinates.
    func rowRects(for range: NSRange) -> [CGRect] {
        let origin = textOrigin
        var rects: [CGRect] = []
        forEachRow(of: range, lines: layoutLines(covering: range)) { start, rowStart, rowEnd, ctLine, top, _ in
            let (minX, maxX) = rowSpan(ctLine, from: max(range.location, rowStart) - start, to: min(range.upperBound, rowEnd) - start)
            rects.append(CGRect(x: origin.x + minX, y: top, width: max(maxX - minX, 1), height: lineHeight))
        }
        return rects
    }

    /// The characters of `range`, as the find indicator shows them.
    func drawCharacters(in range: NSRange) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = textOrigin
        forEachRow(of: range, lines: layoutLines(covering: range)) { start, rowStart, rowEnd, ctLine, top, _ in
            let (minX, maxX) = rowSpan(ctLine, from: max(range.location, rowStart) - start, to: min(range.upperBound, rowEnd) - start)
            context.saveGState()
            context.clip(to: CGRect(x: origin.x + minX, y: top, width: maxX - minX, height: lineHeight))
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.setFillColor(textColor.cgColor)
            context.textPosition = CGPoint(x: origin.x, y: top + layout.baseline)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }
}

/// `NSTextFinderClient` for a ``VimTextView``. A separate object, because
/// the protocol's `selectedRanges` (`[NSValue]`) clashes with the view's.
@MainActor
final class VimTextFinderClient: NSObject, @preconcurrency NSTextFinderClient {
    weak var view: VimTextView?

    init(view: VimTextView) {
        self.view = view
    }

    var string: String { view?.string ?? "" }
    var isSelectable: Bool { true }
    var allowsMultipleSelection: Bool { false }
    var isEditable: Bool { view?.isEditable ?? false }

    var firstSelectedRange: NSRange {
        view?.findSelectionOverride ?? view?.selectedRange() ?? NSRange(location: 0, length: 0)
    }

    var selectedRanges: [NSValue] {
        get {
            if let override = view?.findSelectionOverride { return [NSValue(range: override)] }
            return (view?.selectedRanges ?? []).map { NSValue(range: $0) }
        }
        set { view?.setSelectedRanges(newValue.map(\.rangeValue)) }
    }

    var visibleCharacterRanges: [NSValue] {
        view.map { [NSValue(range: $0.accessibilityVisibleCharacterRange())] } ?? []
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let view else { return }
        let rects = view.rowRects(for: range)
        guard let first = rects.first else { return }
        view.scrollTextToVisible(rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: 0, dy: -view.lineHeight))
    }

    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
        guard let view, view.isEditable else { return false }
        view.textFinderEditing = true
        return true
    }

    func replaceCharacters(in range: NSRange, with string: String) {
        // Replace All sends every match: tell the app once, at the end.
        view?.replace(range, with: string, notify: false)
    }

    func didReplaceCharacters() {
        guard let view, view.textFinderEditing else { return }
        view.textFinderEditing = false
        view.textDidChange()
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        guard let view else { return NSView() }
        outRange.pointee = NSRange(location: 0, length: view.textStorage.length)
        return view
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        view?.rowRects(for: range).map { NSValue(rect: $0) }
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        self.view?.drawCharacters(in: range)
    }
}
#endif
