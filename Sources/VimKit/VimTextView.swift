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
    private let geometry = TextKit2Geometry()

    /// The shared TextKit 2 geometry, or nil when the view uses TextKit 1.
    private var textKit2: TextKit2Geometry? {
        guard let textLayoutManager else { return nil }
        if geometry.layoutManager !== textLayoutManager { geometry.layoutManager = textLayoutManager }
        return geometry
    }

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
        if let textStorage {
            NotificationCenter.default.addObserver(
                self, selector: #selector(vimTextStorageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification, object: textStorage
            )
        }
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

    /// Rectangle of the character at `offset` in view coordinates. At a line
    /// end (or the end of the text) it is a space-wide box.
    public func characterRect(at offset: Int) -> CGRect? {
        let text = string as NSString
        let origin = textContainerOrigin
        if let textKit2 {
            return textKit2.characterRect(at: offset, text: text, spaceWidth: spaceWidth, lineHeight: lineHeight)?
                .offsetBy(dx: origin.x, dy: origin.y)
        }
        guard let layoutManager, let textContainer else { return nil }
        let offset = max(0, min(offset, text.length))
        let isCharacter = offset < text.length && text.character(at: offset) != 0x0A
        let length = isCharacter ? text.rangeOfComposedCharacterSequence(at: offset).length : 0
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: max(length, 1)), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).offsetBy(dx: origin.x, dy: origin.y)
        if !isCharacter || rect.width < 1 { rect.size.width = spaceWidth }
        if rect.height < 1 { rect.size.height = lineHeight }
        return rect
    }

    @objc private func vimTextStorageDidProcessEditing(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage else { return }
        geometry.noteEdit(at: storage.editedRange.location)
    }

    /// Offset of the character at `point` (view coordinates), laying out that
    /// part of the text first. Unlike `characterIndexForInsertion(at:)`, this
    /// also works outside the laid-out viewport (TextKit 2).
    public func characterIndex(at point: CGPoint) -> Int {
        guard let textKit2 else { return characterIndexForInsertion(at: point) }
        let origin = textContainerOrigin
        return textKit2.characterIndex(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y), text: string as NSString)
    }

    // MARK: Search highlight

    private func updateSearchHighlight() {
        let matches = isVimEnabled ? vim.searchMatches(limit: 5_000) : []
        if let textKit2 {
            textKit2.setHighlights(matches, color: searchHighlightColor)
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
    public func vimEngineWillApplyEdits(_ engine: VimEngine) {
        syncSuppression += 1
        textStorage?.beginEditing()
    }

    public func vimEngine(_ engine: VimEngine, replaceCharactersIn range: NSRange, with text: String) {
        guard let textStorage else { return }
        // The engine owns the text: apply even if a delegate would veto it.
        _ = shouldChangeText(in: range, replacementString: text)
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
    }

    public func vimEngineDidApplyEdits(_ engine: VimEngine) {
        textStorage?.endEditing()
        didChangeText()
        syncSuppression -= 1
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
        characterIndex(at: point)
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
        // A page is the visible height less half a line, as in CodeMirror.
        let step = byPage ? max(visibleRect.height - lineHeight / 2, lineHeight) : rect.height
        let y = forward ? rect.midY + step : rect.midY - step
        if y < textContainerOrigin.y { return 0 }
        let index = characterIndex(at: NSPoint(x: (goalX ?? rect.minX) + 1, y: y))
        return min(max(index, 0), length)
    }

    public func vimEngine(_ engine: VimEngine, screenLineBoundaryFrom offset: Int, forward: Bool) -> Int? {
        textKit2?.screenLineBoundary(from: offset, forward: forward, text: string as NSString)
    }

    public func vimEngineLineHeight(_ engine: VimEngine) -> CGFloat? { lineHeight }
}
#endif
