#if os(macOS)
import AppKit
@_exported import VimCore

/// An `NSTextView` with Vim keybindings.
///
/// Key presses go to ``vim`` first; whatever vim does not consume (typing in
/// insert mode, Command shortcuts) reaches the text view as usual. Text and
/// selection changes made by either side are mirrored to the other.
///
/// Uses TextKit 2 when created with ``init(frame:options:runtime:)``.
@MainActor
open class VimTextView: NSTextView {
    /// The engine driving this view.
    public let vim: VimEngine

    /// Turns Vim behaviour on or off. Off, the view is a plain `NSTextView`.
    public var isVimEnabled: Bool = true {
        didSet {
            guard isVimEnabled != oldValue else { return }
            if isVimEnabled { vim.setText(string) }
            updateCursorAppearance()
        }
    }

    /// Called whenever mode, pending keys, command line or messages change.
    public var onStatusChange: ((VimStatus) -> Void)?
    /// Called for `:w`.
    public var onSave: (() -> Void)?
    /// Called for ex commands defined with `vim.defineEx` without a handler.
    public var onExCommand: ((VimExCommand) -> Void)?

    /// Color of the insertion point in insert mode and of the block cursor.
    public var caretColor: NSColor = .controlAccentColor {
        didSet { updateCursorAppearance() }
    }
    public var searchHighlightColor: NSColor = .findHighlightColor.withAlphaComponent(0.45) {
        didSet { updateSearchHighlight() }
    }

    private var syncSuppression = 0
    private var pendingEdits: [[(range: NSRange, text: String)]] = []
    private var pendingSelection = false
    private let blockCursor = NSView()

    // MARK: Initialization

    /// Creates a TextKit 2 text view.
    public convenience init(frame frameRect: NSRect = .zero, options: VimOptions, runtime: VimRuntime? = nil) {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: frameRect.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        self.init(frame: frameRect, textContainer: container, engine: VimEngine(options: options, runtime: runtime))
    }

    public init(frame frameRect: NSRect, textContainer container: NSTextContainer?, engine: VimEngine) {
        vim = engine
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    public override convenience init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        self.init(frame: frameRect, textContainer: container, engine: VimEngine())
    }

    public required init?(coder: NSCoder) {
        vim = VimEngine()
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        vim.delegate = self
        isRichText = false
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        blockCursor.wantsLayer = true
        blockCursor.isHidden = true
        addSubview(blockCursor)
        vim.setText(string)
        updateCursorAppearance()
    }

    // MARK: Keyboard

    open override func keyDown(with event: NSEvent) {
        guard isVimEnabled, !hasMarkedText(), let key = VimKeyEvent(event) else {
            super.keyDown(with: event)
            return
        }
        if vim.handle(key) { return }
        super.keyDown(with: event)
    }

    @objc open func undo(_ sender: Any?) {
        if isVimEnabled { vim.undo() } else { undoManager?.undo() }
    }

    @objc open func redo(_ sender: Any?) {
        if isVimEnabled { vim.redo() } else { undoManager?.redo() }
    }

    open override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) {
            return isVimEnabled || (item.action == #selector(undo(_:)) ? undoManager?.canUndo : undoManager?.canRedo) == true
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: View → engine

    open override var string: String {
        get { super.string }
        set {
            super.string = newValue
            if isVimEnabled { vim.setText(newValue) }
            updateBlockCursor()
        }
    }

    open override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let allowed = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if allowed, isVimEnabled, syncSuppression == 0,
           let replacementStrings, replacementStrings.count == affectedRanges.count {
            pendingEdits.append(zip(affectedRanges, replacementStrings).map { ($0.rangeValue, $1) })
        }
        return allowed
    }

    open override func didChangeText() {
        flushPendingEdits()
        super.didChangeText()
    }

    open override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard isVimEnabled, syncSuppression == 0, !stillSelecting else { return }
        if !pendingEdits.isEmpty {
            // The text change this selection belongs to has not reached the engine yet.
            pendingSelection = true
            return
        }
        forwardSelection()
    }

    private func flushPendingEdits() {
        guard !pendingEdits.isEmpty else { return }
        let batches = pendingEdits
        pendingEdits = []
        for batch in batches {
            // Ranges within one batch refer to the same text; apply back to front.
            for edit in batch.sorted(by: { $0.range.location > $1.range.location }) {
                vim.replaceCharacters(in: edit.range, with: edit.text)
            }
        }
        if pendingSelection {
            pendingSelection = false
            forwardSelection()
        }
        updateBlockCursor()
    }

    private func forwardSelection() {
        vim.setSelections(selectedRanges.map { VimSelection($0.rangeValue) })
        updateBlockCursor()
    }

    /// Re-reads the text into the engine after the text storage was edited
    /// directly (bypassing `NSTextView`). Clears vim's undo history.
    public func resyncEngine() {
        vim.setText(string)
        forwardSelection()
    }

    // MARK: Cursor

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateBlockCursor()
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBlockCursor()
    }

    private var showsBlockCursor: Bool {
        isVimEnabled && !vim.mode.isInsertLike
    }

    private func updateCursorAppearance() {
        insertionPointColor = showsBlockCursor ? .clear : caretColor
        blockCursor.layer?.backgroundColor = caretColor.withAlphaComponent(0.45).cgColor
        updateBlockCursor()
    }

    private func updateBlockCursor() {
        guard showsBlockCursor, let rect = characterRect(at: vim.status.cursorOffset) else {
            blockCursor.isHidden = true
            return
        }
        blockCursor.frame = rect.integral
        blockCursor.isHidden = false
    }

    // MARK: Geometry

    private var effectiveFont: NSFont {
        font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    private var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: effectiveFont)
    }

    private var spaceWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: effectiveFont]).width
    }

    private func textRange(for range: NSRange) -> NSTextRange? {
        guard let manager = textLayoutManager?.textContentManager,
              let start = manager.location(manager.documentRange.location, offsetBy: range.location),
              let end = manager.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Rectangle of the character at `offset` in view coordinates. At a line
    /// end (or the end of the text) it is a space-wide box.
    public func characterRect(at offset: Int) -> CGRect? {
        let text = string as NSString
        let offset = max(0, min(offset, text.length))
        let isCharacter = offset < text.length && text.character(at: offset) != 0x0A
        let length = isCharacter ? text.rangeOfComposedCharacterSequence(at: offset).length : 0
        var rect: CGRect?

        if let layoutManager = textLayoutManager {
            guard let range = textRange(for: NSRange(location: offset, length: length)) else { return nil }
            layoutManager.ensureLayout(for: range)
            layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                rect = rect.map { $0.union(frame) } ?? frame
                return true
            }
        } else if let layoutManager, let textContainer {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: max(length, 1)), actualCharacterRange: nil)
            rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        }

        guard var rect else {
            if text.length == 0 {
                let origin = textContainerOrigin
                let padding = textContainer?.lineFragmentPadding ?? 0
                return CGRect(x: origin.x + padding, y: origin.y, width: spaceWidth, height: lineHeight)
            }
            return nil
        }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        if !isCharacter || rect.width < 1 { rect.size.width = spaceWidth }
        if rect.height < 1 { rect.size.height = lineHeight }
        return rect
    }

    // MARK: Search highlight

    private func updateSearchHighlight() {
        let matches = isVimEnabled ? vim.searchMatches(limit: 5_000) : []
        if let layoutManager = textLayoutManager {
            layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
            for match in matches {
                if let range = textRange(for: match) {
                    layoutManager.addRenderingAttribute(.backgroundColor, value: searchHighlightColor, for: range)
                }
            }
        } else if let layoutManager {
            let all = NSRange(location: 0, length: (string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            for match in matches {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: searchHighlightColor, forCharacterRange: match)
            }
        }
    }
}

// MARK: - VimEngineDelegate

extension VimTextView: VimEngineDelegate {
    public func vimEngine(_ engine: VimEngine, replaceCharactersIn range: NSRange, with text: String) {
        guard let textStorage else { return }
        syncSuppression += 1
        defer { syncSuppression -= 1 }
        // The engine owns the text: apply even if a delegate would veto it.
        _ = shouldChangeText(in: range, replacementString: text)
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        didChangeText()
    }

    public func vimEngine(_ engine: VimEngine, setSelections selections: [VimSelection], primary: Int) {
        syncSuppression += 1
        defer { syncSuppression -= 1 }
        let length = (string as NSString).length
        var ranges = selections.map { selection -> NSValue in
            let start = max(0, min(selection.range.location, length))
            let end = max(start, min(selection.range.location + selection.range.length, length))
            return NSValue(range: NSRange(location: start, length: end - start))
        }
        if ranges.indices.contains(primary), primary != 0 {
            ranges.swapAt(0, primary)
        }
        setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false)
        updateBlockCursor()
    }

    public func vimEngineDidChangeStatus(_ engine: VimEngine) {
        updateCursorAppearance()
        onStatusChange?(engine.status)
    }

    public func vimEngineDidRequestSave(_ engine: VimEngine) { onSave?() }

    public func vimEngine(_ engine: VimEngine, didRun command: VimExCommand) { onExCommand?(command) }

    public func vimEngineDidRequestFocus(_ engine: VimEngine) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    public func vimEngineSearchHighlightDidChange(_ engine: VimEngine) { updateSearchHighlight() }

    public func vimEngine(_ engine: VimEngine, rectForCharacterAt offset: Int) -> CGRect? {
        characterRect(at: offset)
    }

    public func vimEngine(_ engine: VimEngine, characterIndexAt point: CGPoint) -> Int? {
        characterIndexForInsertion(at: point)
    }

    public func vimEngineScrollInfo(_ engine: VimEngine) -> VimScrollInfo? {
        guard enclosingScrollView != nil else { return nil }
        return VimScrollInfo(visibleRect: visibleRect, contentSize: bounds.size)
    }

    public func vimEngine(_ engine: VimEngine, scrollToX x: CGFloat?, y: CGFloat?) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        if let x { origin.x = x }
        if let y { origin.y = y }
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    public func vimEngine(_ engine: VimEngine, scrollCharacterToVisible offset: Int, margin: CGFloat) {
        if let rect = characterRect(at: offset) {
            scrollToVisible(rect.insetBy(dx: 0, dy: -margin))
        } else {
            scrollRangeToVisible(NSRange(location: offset, length: 0))
        }
    }

    public func vimEngine(_ engine: VimEngine, verticalMoveFrom offset: Int, forward: Bool, byPage: Bool, goalX: CGFloat?) -> Int? {
        guard let rect = characterRect(at: offset) else { return nil }
        let length = (string as NSString).length
        let step = byPage ? max(visibleRect.height - lineHeight, lineHeight) : rect.height
        let y = forward ? rect.midY + step : rect.midY - step
        if y < textContainerOrigin.y { return 0 }
        if let last = characterRect(at: length), y > last.maxY { return length }
        let index = characterIndexForInsertion(at: NSPoint(x: (goalX ?? rect.minX) + 1, y: y))
        return min(max(index, 0), length)
    }

    public func vimEngine(_ engine: VimEngine, screenLineBoundaryFrom offset: Int, forward: Bool) -> Int? {
        guard let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset),
              let fragment = layoutManager.textLayoutFragment(for: location)
        else { return nil }
        let text = string as NSString
        let fragmentStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let lines = fragment.textLineFragments
        for (index, line) in lines.enumerated() {
            let start = fragmentStart + line.characterRange.location
            let end = start + line.characterRange.length
            guard offset >= start, offset < end || index == lines.count - 1 else { continue }
            if !forward { return start }
            var result = min(end, text.length)
            if result > start, text.character(at: result - 1) == 0x0A { result -= 1 }
            return result
        }
        return nil
    }

    public func vimEngineLineHeight(_ engine: VimEngine) -> CGFloat? { lineHeight }
}
#endif
