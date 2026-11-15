#if os(macOS)
import AppKit
import CoreText
@_exported import VimCore

/// A code editor view with Vim keybindings.
///
/// Key presses go to ``vim`` first; whatever vim does not consume (typing in
/// insert mode, Command shortcuts) is handled like in a text view: through the
/// input method (`NSTextInputClient`), the standard editing commands and the
/// Edit menu. Text and selection changes made by either side are mirrored to
/// the other.
///
/// The view lays out and draws its text itself (``VimTextLayout``): every
/// line's position is exact, so the document height, the scroller and far
/// jumps don't depend on estimates. Put it in an `NSScrollView` as the
/// document view; it sizes itself to the clip view and the text.
@MainActor
open class VimTextView: NSView, @preconcurrency NSTextInputClient, NSUserInterfaceValidations {
    /// The engine driving this view.
    public let vim: VimEngine

    /// The text. Edit it through ``string``, the engine or user input; direct
    /// character edits are shown but reach the engine only through
    /// ``resyncEngine()``. Attributes are yours: `.foregroundColor` colors the
    /// text, `.vimTokenType` guides `%` and `=`.
    public let textStorage = NSTextStorage()

    let layout: VimTextLayout

    /// Turns Vim behaviour on or off. Off, the view is a plain text editor.
    public var isVimEnabled: Bool = true {
        didSet {
            guard isVimEnabled != oldValue else { return }
            if isVimEnabled {
                vim.setText(string)
                forwardSelection()
            }
            applyFolds()
            searchArea = nil
            updateCursor()
        }
    }

    /// Called whenever mode, pending keys, command line or messages change.
    public var onStatusChange: ((VimStatus) -> Void)?
    /// Called for `:w`.
    public var onSave: (() -> Void)?
    /// Called for ex commands defined with `vim.defineEx` without a handler.
    public var onExCommand: ((VimExCommand) -> Void)?
    /// Called after every change of the text (also posted as `NSText.didChangeNotification`).
    public var onTextChange: (() -> Void)?

    /// Color of the insertion point in insert mode and of the block cursor.
    public var caretColor: NSColor = .controlAccentColor {
        didSet { updateCursor() }
    }
    public var searchHighlightColor: NSColor = .findHighlightColor.withAlphaComponent(0.45) {
        didSet { needsDisplay = true }
    }
    public var textColor: NSColor = .textColor {
        didSet { needsDisplay = true }
    }
    public var backgroundColor: NSColor = .textBackgroundColor {
        didSet { needsDisplay = true }
    }
    public var drawsBackground = true {
        didSet { needsDisplay = true }
    }
    public var selectedTextBackgroundColor: NSColor = .selectedTextBackgroundColor {
        didSet { needsDisplay = true }
    }
    /// Whether typing, pasting and the engine may change the text.
    public var isEditable = true

    /// Tells vim whether the character before an offset is in a string or a
    /// comment (for `%` and `=`). When nil, the `.vimTokenType` text attribute is used.
    public var tokenTypeProvider: ((Int) -> VimTokenType?)?

    public var font: NSFont {
        didSet {
            guard font != oldValue else { return }
            layout.setFont(font)
            geometryDidChange()
        }
    }

    /// Space around the text.
    public var textContainerInset: NSSize = .zero {
        didSet { if textContainerInset != oldValue { geometryDidChange() } }
    }

    /// Wrap long lines at the view's width (default); off, the view grows
    /// sideways to the widest line.
    public var wrapsLines = true {
        didSet { if wrapsLines != oldValue { geometryDidChange() } }
    }

    /// Gap between the inset and the text on the left and right.
    private let padding: CGFloat = 5

    private var syncSuppression = 0
    private var folds: [VimFold] = []
    private var markedTextRange: NSRange?
    private var storageObserver: (any NSObjectProtocol)?
    private var clipObserver: (any NSObjectProtocol)?

    // MARK: Initialization

    public convenience init(frame frameRect: NSRect = .zero, options: VimOptions, runtime: VimRuntime? = nil) {
        self.init(frame: frameRect, engine: VimEngine(options: options, runtime: runtime), tabSize: options.tabSize)
    }

    public init(frame frameRect: NSRect, engine: VimEngine, tabSize: Int = 4) {
        vim = engine
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        self.font = font
        layout = VimTextLayout(text: textStorage.mutableString, font: font, tabWidth: tabSize)
        super.init(frame: frameRect)
        commonInit()
    }

    public override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, engine: VimEngine())
    }

    public required init?(coder: NSCoder) {
        vim = VimEngine()
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        self.font = font
        layout = VimTextLayout(text: textStorage.mutableString, font: font)
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        vim.delegate = self
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layout.setWrapWidth(wrapWidth(for: bounds.width))
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storageDidProcessEditing() }
        }
        vim.setText(string)
        updateCursor()
    }

    // MARK: Text

    /// The whole text. Setting it resets the engine (and its undo history).
    public var string: String {
        get { textStorage.string }
        set {
            markedTextRange = nil
            syncSuppression += 1
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                          with: NSAttributedString(string: newValue))
            selectedRanges = [NSRange(location: 0, length: 0)]
            syncSuppression -= 1
            undoManager?.removeAllActions(withTarget: self)
            if isVimEnabled { vim.setText(newValue) }
            updateCursor()
        }
    }

    /// Re-reads the text into the engine after ``textStorage`` was edited
    /// directly. Clears vim's undo history.
    public func resyncEngine() {
        vim.setText(string)
        forwardSelection()
    }

    private func storageDidProcessEditing() {
        if textStorage.editedMask.contains(.editedCharacters) {
            layout.textDidChange(editedRange: textStorage.editedRange, changeInLength: textStorage.changeInLength)
            let length = textStorage.length
            selectedRanges = selectedRanges.map { clamp($0, to: length) }
            if let marked = markedTextRange, marked.upperBound > length { markedTextRange = nil }
            updateFrameSize()
        }
        coloredLines = [:]
        needsDisplay = true
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let start = max(0, min(range.location, length))
        return NSRange(location: start, length: max(0, min(range.location + range.length, length) - start))
    }

    /// A user edit (typing, input method, paste, editing commands): applied
    /// to the text and sent to the engine.
    private func replace(_ range: NSRange, with text: String, selection: NSRange? = nil) {
        guard isEditable else {
            NSSound.beep()
            return
        }
        let range = clamp(range, to: textStorage.length)
        let length = (text as NSString).length
        if !isVimEnabled, let undoManager {
            let old = textStorage.attributedSubstring(from: range).string
            let inserted = NSRange(location: range.location, length: length)
            undoManager.registerUndo(withTarget: self) { view in
                view.replace(inserted, with: old, selection: NSRange(location: inserted.location + (old as NSString).length, length: 0))
            }
        }
        syncSuppression += 1
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text))
        syncSuppression -= 1
        if isVimEnabled { vim.replaceCharacters(in: range, with: text) }
        setSelectedRanges([selection ?? NSRange(location: range.location + length, length: 0)])
        textDidChange()
    }

    private func textDidChange() {
        onTextChange?()
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: self)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: Selection

    /// Selected ranges; the first is the primary one.
    public private(set) var selectedRanges: [NSRange] = [NSRange(location: 0, length: 0)]
    /// The end of the selection that stays put when it is extended.
    private var selectionAnchor: Int?
    /// x the caret keeps while moving up and down.
    private var goalX: CGFloat?

    public func selectedRange() -> NSRange { selectedRanges.first ?? NSRange(location: 0, length: 0) }

    public func setSelectedRange(_ range: NSRange) { setSelectedRanges([range]) }

    public func setSelectedRanges(_ ranges: [NSRange]) {
        showSelection(ranges)
        guard syncSuppression == 0 else { return }
        forwardSelection()
    }

    /// Shows a selection without telling the engine.
    private func showSelection(_ ranges: [NSRange]) {
        let length = textStorage.length
        let ranges = ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges.map { clamp($0, to: length) }
        guard ranges != selectedRanges else { return }
        selectedRanges = ranges
        needsDisplay = true
        updateCursor()
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    private func forwardSelection() {
        guard isVimEnabled else { return }
        vim.setSelections(selectedRanges.map { VimSelection($0) })
        updateCursor()
    }

    // MARK: Geometry

    /// Top left of the text in view coordinates.
    private var textOrigin: CGPoint {
        CGPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
    }

    private func wrapWidth(for width: CGFloat) -> CGFloat {
        wrapsLines ? max(width - 2 * (textContainerInset.width + padding), layout.spaceWidth) : .infinity
    }

    private var lineHeight: CGFloat { layout.rowHeight }

    /// Rectangle of the character at `offset` in view coordinates, or nil
    /// when it is folded away. At a line end (or the end of the text) it is a
    /// space-wide box.
    public func characterRect(at offset: Int) -> CGRect? {
        let offset = max(0, min(offset, textStorage.length))
        guard !layout.isHidden(layout.line(containing: offset)) else { return nil }
        return layoutRect(at: offset)
    }

    /// Like ``characterRect(at:)``, but a folded character reports the end
    /// of the fold's header line.
    private func layoutRect(at offset: Int) -> CGRect {
        let origin = textOrigin
        return layout.characterRect(at: offset).offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Offset of the character at `point` (view coordinates).
    public func characterIndex(at point: CGPoint) -> Int {
        let origin = textOrigin
        return layout.characterIndex(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
    }

    /// The caret position nearest to `point`: before or after the character under it.
    private func insertionIndex(at point: CGPoint) -> Int {
        let index = characterIndex(at: point)
        guard index < textStorage.length, textStorage.mutableString.character(at: index) != 0x0A else { return index }
        let rect = layoutRect(at: index)
        guard point.x > rect.midX, point.y >= rect.minY, point.y < rect.maxY else { return index }
        return index + textStorage.mutableString.rangeOfComposedCharacterSequence(at: index).length
    }

    private func geometryDidChange() {
        layout.setWrapWidth(wrapWidth(for: bounds.width))
        coloredLines = [:]
        updateFrameSize()
        needsDisplay = true
        updateCursor()
    }

    /// Fills the clip view's width (or the widest line) and the text's exact height.
    private func updateFrameSize() {
        guard let clip = superview as? NSClipView else { return }
        let size = clip.bounds.size
        let origin = textOrigin
        let width = wrapsLines ? size.width
            : max(size.width, ceil(layout.widestLineWidth() + 2 * origin.x + layout.spaceWidth))
        layout.setWrapWidth(wrapWidth(for: width))
        let height = max(size.height, ceil(layout.height + 2 * textContainerInset.height))
        let frameSize = NSSize(width: width, height: height)
        if frame.size != frameSize { super.setFrameSize(frameSize) }
    }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let wrap = wrapWidth(for: newSize.width)
        if wrap != layout.wrapWidth {
            layout.setWrapWidth(wrap)
            updateFrameSize()
            updateCursor()
        }
    }

    open override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        clipObserver = nil
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrameSize() }
        }
        updateFrameSize()
    }

    open override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopBlinking() }
    }

    open override var isFlipped: Bool { true }

    open override var isOpaque: Bool { drawsBackground && backgroundColor.alphaComponent >= 1 }

    open override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .iBeam)
    }

    // MARK: Cursor

    private var showsBlockCursor: Bool { isVimEnabled && !vim.mode.isInsertLike }

    /// Where the block cursor is drawn (view coordinates), or nil when hidden.
    private(set) var blockCursorFrame: CGRect?
    /// The character the block cursor inverts; nil where there is none (line ends).
    private(set) var invertedCursorRange: NSRange?
    /// Whether the cursor is drawn as a box (where there is no character to invert).
    var showsCursorBox: Bool { blockCursorFrame != nil && invertedCursorRange == nil }
    /// The insertion point in insert mode (or with Vim off).
    private var caretFrame: CGRect?
    private var caretVisible = true
    private var blinkTimer: Timer?

    /// Text color of the character under the block cursor.
    private var cursorTextColor: NSColor {
        drawsBackground && backgroundColor.alphaComponent > 0 ? backgroundColor : .textBackgroundColor
    }

    /// Nesting depth of ``coalescingCursorUpdates(_:)``.
    private var cursorUpdatesDeferred = 0
    private var cursorNeedsUpdate = false

    /// Runs `body` with cursor updates folded into one at the end. One key
    /// can change mode and selection thousands of times (`:%norm`, macros).
    private func coalescingCursorUpdates<T>(_ body: () -> T) -> T {
        cursorUpdatesDeferred += 1
        defer {
            cursorUpdatesDeferred -= 1
            if cursorUpdatesDeferred == 0, cursorNeedsUpdate {
                cursorNeedsUpdate = false
                updateCursor()
            }
        }
        return body()
    }

    private func updateCursor() {
        if cursorUpdatesDeferred > 0 {
            cursorNeedsUpdate = true
            return
        }
        let previous = [blockCursorFrame, caretFrame].compactMap { $0 }
        blockCursorFrame = nil
        invertedCursorRange = nil
        caretFrame = nil
        if showsBlockCursor {
            let offset = max(0, min(vim.status.cursorOffset, textStorage.length))
            if let rect = characterRect(at: offset) {
                blockCursorFrame = rect
                if offset < textStorage.length, ![0x0A, 0x0D].contains(textStorage.mutableString.character(at: offset)) {
                    invertedCursorRange = textStorage.mutableString.rangeOfComposedCharacterSequence(at: offset)
                }
            }
        } else if selectedRange().length == 0 {
            let rect = layoutRect(at: selectedRange().location)
            caretFrame = CGRect(x: rect.minX - 1, y: rect.minY, width: 2, height: rect.height)
        }
        for rect in previous + [blockCursorFrame, caretFrame].compactMap({ $0 }) {
            setNeedsDisplay(rect.insetBy(dx: -2, dy: -1))
        }
        restartBlinking()
    }

    private func restartBlinking() {
        caretVisible = true
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard caretFrame != nil, window?.firstResponder === self else { return }
        let interval = max(0.2, (UserDefaults.standard.object(forKey: "NSTextInsertionPointBlinkPeriodOn") as? Double ?? 560) / 1000)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let caret = self.caretFrame else { return }
                self.caretVisible.toggle()
                self.setNeedsDisplay(caret.insetBy(dx: -2, dy: -1))
            }
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    // MARK: Drawing

    /// Lines whose text has `.foregroundColor` runs, laid out with them.
    private var coloredLines: [Int: [CTLine]] = [:]

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        coloredLines = [:]
        needsDisplay = true
    }

    open override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if drawsBackground {
            backgroundColor.setFill()
            dirtyRect.fill()
        }
        let origin = textOrigin
        let lines = layout.visibleLines(from: dirtyRect.minY - origin.y, to: dirtyRect.maxY - origin.y)
        if let first = lines.first, let last = lines.last {
            let visible = NSRange(location: layout.starts[first.line],
                                  length: layout.lineEnd(last.line) - layout.starts[first.line])
            let isKey = window?.firstResponder === self && window?.isKeyWindow != false
            let selectionColor = isKey ? selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
            for range in selectedRanges where range.length > 0 && NSIntersectionRange(range, NSRange(location: visible.location, length: visible.length + 1)).length > 0 {
                fill(range, color: selectionColor, lines: lines, toEdge: true)
            }
            if isVimEnabled {
                for match in searchMatches(near: visible) {
                    fill(match, color: searchHighlightColor, lines: lines, toEdge: false)
                }
            }
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let plainColor = textColor.cgColor
            for (line, y) in lines {
                let lineLayout = layout.line(line)
                let colored = coloredRows(of: line, layout: lineLayout)
                for row in 0..<lineLayout.rowCount {
                    let top = origin.y + y + CGFloat(row) * lineHeight
                    guard top < dirtyRect.maxY, top + lineHeight > dirtyRect.minY else { continue }
                    // Colored runs leave their color in the context.
                    context.setFillColor(plainColor)
                    context.textPosition = CGPoint(x: origin.x, y: top + layout.baseline)
                    CTLineDraw(colored?[row] ?? lineLayout.ctLine(row: row), context)
                }
            }
            if let marked = markedTextRange { underline(marked, lines: lines) }
            drawFoldPlaceholders(between: visible.location, and: visible.upperBound, in: dirtyRect)
        }
        drawCursor(in: dirtyRect, context: context)
    }

    /// Rows of `line` drawn with the text's `.foregroundColor` runs, or nil
    /// when it has none (the plain layout is drawn in ``textColor``).
    private func coloredRows(of line: Int, layout lineLayout: VimTextLayout.Line) -> [CTLine]? {
        if let cached = coloredLines[line] { return cached.isEmpty ? nil : cached }
        let range = NSRange(location: layout.starts[line], length: lineLayout.length)
        var effective = NSRange()
        let first = range.length > 0
            ? textStorage.attribute(.foregroundColor, at: range.location, longestEffectiveRange: &effective, in: range) : nil
        if range.length == 0 || (first == nil && effective.length == range.length) {
            coloredLines[line] = []
            return nil
        }
        let attributed = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
        let all = NSRange(location: 0, length: attributed.length)
        attributed.setAttributes(layout.attributes, range: all)
        textStorage.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
            guard let color = value as? NSColor else { return }
            attributed.addAttributes([
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): false,
            ], range: NSRange(location: run.location - range.location, length: run.length))
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let rows = (0..<lineLayout.rowCount).map { row -> CTLine in
            let rowRange = lineLayout.rowRange(row)
            return CTTypesetterCreateLine(typesetter, CFRange(location: rowRange.lowerBound, length: rowRange.count))
        }
        coloredLines[line] = rows
        return rows
    }

    /// Calls `body` with each screen row of `lines` that `range` touches:
    /// the row's start and end offsets, its CTLine and top, and whether the
    /// range continues past the row's end (a line break or a wrap).
    private func forEachRow(of range: NSRange, lines: [(line: Int, y: CGFloat)],
                            _ body: (_ start: Int, _ rowStart: Int, _ rowEnd: Int, _ ctLine: CTLine, _ top: CGFloat, _ continues: Bool) -> Void) {
        let origin = textOrigin
        for (line, y) in lines {
            let start = layout.starts[line]
            guard range.location <= layout.lineEnd(line), range.upperBound >= start else { continue }
            let lineLayout = layout.line(line)
            for row in 0..<lineLayout.rowCount {
                let rows = lineLayout.rowRange(row)
                let rowStart = start + rows.lowerBound, rowEnd = start + rows.upperBound
                guard range.location <= rowEnd, range.upperBound >= rowStart else { continue }
                let continues = range.upperBound > rowEnd
                guard range.upperBound > rowStart || continues || range.length == 0 else { continue }
                body(start, rowStart, rowEnd, lineLayout.ctLine(row: row), origin.y + y + CGFloat(row) * lineHeight, continues)
            }
        }
    }

    private func fill(_ range: NSRange, color: NSColor, lines: [(line: Int, y: CGFloat)], toEdge: Bool) {
        color.setFill()
        let origin = textOrigin
        forEachRow(of: range, lines: lines) { start, rowStart, rowEnd, ctLine, top, continues in
            let from = max(range.location, rowStart), to = min(range.upperBound, rowEnd)
            let minX = CTLineGetOffsetForStringIndex(ctLine, from - start, nil)
            let maxX = continues && toEdge ? bounds.width - textContainerInset.width - origin.x
                : continues ? CTLineGetOffsetForStringIndex(ctLine, to - start, nil) + layout.spaceWidth
                : CTLineGetOffsetForStringIndex(ctLine, to - start, nil)
            guard maxX > minX else { return }
            CGRect(x: origin.x + minX, y: top, width: maxX - minX, height: lineHeight).fill()
        }
    }

    private func underline(_ range: NSRange, lines: [(line: Int, y: CGFloat)]) {
        textColor.setFill()
        let origin = textOrigin
        forEachRow(of: range, lines: lines) { start, rowStart, rowEnd, ctLine, top, _ in
            let minX = CTLineGetOffsetForStringIndex(ctLine, max(range.location, rowStart) - start, nil)
            let maxX = CTLineGetOffsetForStringIndex(ctLine, min(range.upperBound, rowEnd) - start, nil)
            CGRect(x: origin.x + minX, y: top + layout.baseline + 2, width: max(maxX - minX, 1), height: 1).fill()
        }
    }

    private func drawCursor(in dirtyRect: CGRect, context: CGContext) {
        if let rect = blockCursorFrame, rect.intersects(dirtyRect) {
            caretColor.setFill()
            rect.fill()
            if let range = invertedCursorRange {
                // The character again, clipped to the box, in the background color.
                let line = layout.line(containing: range.location)
                let lineLayout = layout.line(line)
                let row = lineLayout.row(containing: range.location - layout.starts[line])
                context.saveGState()
                context.clip(to: rect)
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.setFillColor(cursorTextColor.cgColor)
                context.textPosition = CGPoint(x: textOrigin.x, y: rect.minY + layout.baseline)
                CTLineDraw(lineLayout.ctLine(row: row), context)
                context.restoreGState()
            }
        }
        if let caret = caretFrame, caretVisible, caret.intersects(dirtyRect), window?.firstResponder === self {
            caretColor.setFill()
            caret.fill()
        }
    }

    // MARK: Search highlight

    private var searchMatchCache: [NSRange] = []
    /// The text range ``searchMatchCache`` covers; nil when it must be fetched again.
    private var searchArea: NSRange?

    /// Matches of the last search around `visible`, fetched from the engine
    /// for a screen above and below, and again when scrolling leaves that area.
    private func searchMatches(near visible: NSRange) -> [NSRange] {
        if let area = searchArea, area.location <= visible.location, area.upperBound >= visible.upperBound {
            return searchMatchCache
        }
        let length = textStorage.length
        let start = max(0, visible.location - max(visible.length, 4_096))
        let end = min(length, visible.upperBound + max(visible.length, 4_096))
        let area = NSRange(location: start, length: end - start)
        searchMatchCache = vim.searchMatches(in: area, limit: 5_000)
        searchArea = area
        return searchMatchCache
    }

    // MARK: Folding

    private func applyFolds() {
        folds = isVimEnabled ? vim.folds : []
        layout.setHidden(folds.map(\.hiddenRange))
        updateFrameSize()
        needsDisplay = true
        updateCursor()
    }

    private var placeholderFont: NSFont {
        .monospacedSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
    }

    /// The "⋯ N lines" label after a closed fold's header line.
    private func placeholderFrame(for fold: VimFold) -> CGRect? {
        let headerEnd = fold.hiddenRange.location - 1
        guard headerEnd >= 0 else { return nil }
        let header = layoutRect(at: headerEnd)
        let size = (fold.placeholder as NSString).size(withAttributes: [.font: placeholderFont])
        let height = min(ceil(size.height), header.height)
        return CGRect(x: header.minX + layout.spaceWidth, y: header.midY - height / 2, width: ceil(size.width) + 8, height: height).integral
    }

    private func drawFoldPlaceholders(between start: Int, and end: Int, in dirtyRect: CGRect) {
        guard !folds.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: placeholderFont, .foregroundColor: NSColor.secondaryLabelColor]
        for fold in folds.withHeaders(between: start, and: end) {
            guard let frame = placeholderFrame(for: fold), frame.intersects(dirtyRect) else { continue }
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).fill()
            let size = (fold.placeholder as NSString).size(withAttributes: attributes)
            (fold.placeholder as NSString).draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
                                                withAttributes: attributes)
        }
    }

    /// Placeholders of the closed folds within a screen of the visible text, for tests.
    var foldPlaceholders: [(text: String, frame: CGRect)] {
        let visible = visibleRect.isEmpty ? bounds : visibleRect
        let area = visible.insetBy(dx: 0, dy: -visible.height)
        let start = characterIndex(at: CGPoint(x: 0, y: area.minY)), end = characterIndex(at: CGPoint(x: area.maxX, y: area.maxY))
        return folds.withHeaders(between: start, and: max(start, layout.lineEnd(layout.line(containing: end)))).compactMap { fold in
            placeholderFrame(for: fold).map { (fold.placeholder, $0) }
        }
    }

    // MARK: Keyboard

    open override var acceptsFirstResponder: Bool { true }

    open override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        updateCursor()
        return true
    }

    open override func resignFirstResponder() -> Bool {
        needsDisplay = true
        stopBlinking()
        return true
    }

    open override func keyDown(with event: NSEvent) {
        if isVimEnabled, !hasMarkedText(), let key = VimKeyEvent(event), coalescingCursorUpdates({ vim.handle(key) }) {
            return
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        interpretKeyEvents([event])
    }

    open override func doCommand(by selector: Selector) {
        if responds(to: selector) {
            perform(selector, with: nil)
        } else {
            super.doCommand(by: selector)
        }
    }

    @objc open func undo(_ sender: Any?) {
        if isVimEnabled { vim.undo() } else { undoManager?.undo() }
    }

    @objc open func redo(_ sender: Any?) {
        if isVimEnabled { vim.redo() } else { undoManager?.redo() }
    }

    @objc open func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc open func cut(_ sender: Any?) {
        copy(sender)
        if selectedRange().length > 0 { replace(selectedRange(), with: "") }
    }

    @objc open func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    open override func selectAll(_ sender: Any?) {
        setSelectedRange(NSRange(location: 0, length: textStorage.length))
    }

    private var selectedText: String {
        selectedRanges.filter { $0.length > 0 }.map { textStorage.attributedSubstring(from: $0).string }.joined(separator: "\n")
    }

    open func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return isVimEnabled || undoManager?.canUndo == true
        case #selector(redo(_:)): return isVimEnabled || undoManager?.canRedo == true
        case #selector(copy(_:)): return selectedRange().length > 0
        case #selector(cut(_:)): return isEditable && selectedRange().length > 0
        case #selector(paste(_:)): return isEditable && NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)): return true
        default: return responds(to: item.action)
        }
    }

    open override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: Editing commands (typing outside Vim's normal mode)

    open override func insertNewline(_ sender: Any?) { insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    open override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }
    open override func insertTab(_ sender: Any?) { insertText("\t", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    open override func cancelOperation(_ sender: Any?) {}

    open override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0 { return replace(selection, with: "") }
        guard selection.location > 0 else { return }
        let previous = textStorage.mutableString.rangeOfComposedCharacterSequence(at: selection.location - 1)
        replace(NSRange(location: previous.location, length: selection.location - previous.location), with: "")
    }

    open override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0 { return replace(selection, with: "") }
        guard selection.location < textStorage.length else { return }
        replace(textStorage.mutableString.rangeOfComposedCharacterSequence(at: selection.location), with: "")
    }

    open override func deleteWordBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0 { return replace(selection, with: "") }
        let start = textStorage.nextWord(from: selection.location, forward: false)
        replace(NSRange(location: start, length: selection.location - start), with: "")
    }

    open override func deleteToBeginningOfLine(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0 { return replace(selection, with: "") }
        let start = layout.screenLineBoundary(from: selection.location, forward: false)
        replace(NSRange(location: start, length: selection.location - start), with: "")
    }

    /// Moves the caret (or the selection's moving end when `extending`) to `offset`.
    private func move(to offset: Int, extending: Bool, keepGoal: Bool = false) {
        let offset = max(0, min(offset, textStorage.length))
        if !keepGoal { goalX = nil }
        if extending {
            let anchor = selectionAnchor ?? selectedRange().location
            selectionAnchor = anchor
            setSelectedRange(NSRange(location: min(anchor, offset), length: abs(offset - anchor)))
        } else {
            selectionAnchor = nil
            setSelectedRange(NSRange(location: offset, length: 0))
        }
        if let rect = characterRect(at: offset) { scrollToVisible(rect) }
    }

    /// The moving end of the selection.
    private var head: Int {
        let selection = selectedRange()
        guard let anchor = selectionAnchor, selection.length > 0 else { return selection.location }
        return anchor == selection.location ? selection.upperBound : selection.location
    }

    private func step(from offset: Int, forward: Bool) -> Int {
        let text = textStorage.mutableString
        if forward { return offset < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset)) : offset }
        return offset > 0 ? text.rangeOfComposedCharacterSequence(at: offset - 1).location : 0
    }

    private func vertical(from offset: Int, forward: Bool, distance: CGFloat) -> Int {
        let rect = layoutRect(at: offset)
        let x = goalX ?? rect.minX
        goalX = x
        let y = forward ? rect.midY + distance : rect.midY - distance
        if y < textOrigin.y { return 0 }
        if y > textOrigin.y + layout.height { return textStorage.length }
        return insertionIndex(at: CGPoint(x: x, y: y))
    }

    open override func moveLeft(_ sender: Any?) {
        let selection = selectedRange()
        move(to: selection.length > 0 ? selection.location : step(from: selection.location, forward: false), extending: false)
    }

    open override func moveRight(_ sender: Any?) {
        let selection = selectedRange()
        move(to: selection.length > 0 ? selection.upperBound : step(from: selection.location, forward: true), extending: false)
    }

    open override func moveLeftAndModifySelection(_ sender: Any?) { move(to: step(from: head, forward: false), extending: true) }
    open override func moveRightAndModifySelection(_ sender: Any?) { move(to: step(from: head, forward: true), extending: true) }
    open override func moveUp(_ sender: Any?) { move(to: vertical(from: head, forward: false, distance: lineHeight), extending: false, keepGoal: true) }
    open override func moveDown(_ sender: Any?) { move(to: vertical(from: head, forward: true, distance: lineHeight), extending: false, keepGoal: true) }
    open override func moveUpAndModifySelection(_ sender: Any?) { move(to: vertical(from: head, forward: false, distance: lineHeight), extending: true, keepGoal: true) }
    open override func moveDownAndModifySelection(_ sender: Any?) { move(to: vertical(from: head, forward: true, distance: lineHeight), extending: true, keepGoal: true) }
    open override func moveWordLeft(_ sender: Any?) { move(to: textStorage.nextWord(from: head, forward: false), extending: false) }
    open override func moveWordRight(_ sender: Any?) { move(to: textStorage.nextWord(from: head, forward: true), extending: false) }
    open override func moveWordLeftAndModifySelection(_ sender: Any?) { move(to: textStorage.nextWord(from: head, forward: false), extending: true) }
    open override func moveWordRightAndModifySelection(_ sender: Any?) { move(to: textStorage.nextWord(from: head, forward: true), extending: true) }
    open override func moveToBeginningOfLine(_ sender: Any?) { move(to: layout.screenLineBoundary(from: head, forward: false), extending: false) }
    open override func moveToEndOfLine(_ sender: Any?) { move(to: rowEnd(head), extending: false) }
    open override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
    open override func moveToRightEndOfLine(_ sender: Any?) { moveToEndOfLine(sender) }
    open override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { move(to: layout.screenLineBoundary(from: head, forward: false), extending: true) }
    open override func moveToEndOfLineAndModifySelection(_ sender: Any?) { move(to: rowEnd(head), extending: true) }
    open override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { moveToBeginningOfLineAndModifySelection(sender) }
    open override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { moveToEndOfLineAndModifySelection(sender) }
    open override func moveToBeginningOfDocument(_ sender: Any?) { move(to: 0, extending: false) }
    open override func moveToEndOfDocument(_ sender: Any?) { move(to: textStorage.length, extending: false) }
    open override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(to: 0, extending: true) }
    open override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(to: textStorage.length, extending: true) }
    open override func pageUp(_ sender: Any?) { move(to: vertical(from: head, forward: false, distance: pageHeight), extending: false, keepGoal: true) }
    open override func pageDown(_ sender: Any?) { move(to: vertical(from: head, forward: true, distance: pageHeight), extending: false, keepGoal: true) }
    open override func scrollPageUp(_ sender: Any?) { scrollBy(-pageHeight) }
    open override func scrollPageDown(_ sender: Any?) { scrollBy(pageHeight) }
    open override func scrollToBeginningOfDocument(_ sender: Any?) { scroll(.zero) }
    open override func scrollToEndOfDocument(_ sender: Any?) { scroll(CGPoint(x: 0, y: bounds.height)) }

    private var pageHeight: CGFloat { max(visibleRect.height - lineHeight, lineHeight) }

    private func scrollBy(_ dy: CGFloat) {
        scroll(CGPoint(x: visibleRect.minX, y: visibleRect.minY + dy))
    }

    /// End of the screen row containing `offset`, before a wrapped row's last character.
    private func rowEnd(_ offset: Int) -> Int {
        let end = layout.screenLineBoundary(from: offset, forward: true)
        let line = layout.line(containing: offset)
        return end < layout.lineEnd(line) ? step(from: end, forward: false) : end
    }

    // MARK: Mouse

    open override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if hasMarkedText(), inputContext?.handleEvent(event) == true { return }
        let point = convert(event.locationInWindow, from: nil)
        // Vim's normal mode puts the cursor on the character clicked.
        let index = showsBlockCursor ? characterIndex(at: point) : insertionIndex(at: point)
        let text = textStorage.mutableString
        let clicks = event.clickCount
        func unit(at index: Int) -> NSRange {
            switch clicks {
            case 2: return index < text.length ? textStorage.doubleClick(at: index) : NSRange(location: index, length: 0)
            case 3...: return text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
            default: return NSRange(location: index, length: 0)
            }
        }
        var anchor = unit(at: index)
        if event.modifierFlags.contains(.shift), clicks == 1 {
            let current = selectedRange()
            anchor = NSRange(location: index < current.location ? current.upperBound : current.location, length: 0)
        }
        var selection = NSUnionRange(anchor, unit(at: index))
        goalX = nil
        selectionAnchor = nil
        showSelection([selection])
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            self.autoscroll(with: event)
            let index = self.insertionIndex(at: self.convert(event.locationInWindow, from: nil))
            selection = NSUnionRange(anchor, unit(at: index))
            self.showSelection([selection])
        }
        selectedRanges = []
        setSelectedRanges([selection])
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let range = replacementRange.location != NSNotFound ? replacementRange : markedTextRange ?? selectedRange()
        markedTextRange = nil
        replace(range, with: text)
        inputContext?.invalidateCharacterCoordinates()
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let range = replacementRange.location != NSNotFound ? replacementRange : markedTextRange ?? self.selectedRange()
        let length = (text as NSString).length
        replace(range, with: text, selection: NSRange(location: range.location + min(selectedRange.location, length),
                                                      length: min(selectedRange.length, length)))
        markedTextRange = length > 0 ? NSRange(location: clamp(range, to: textStorage.length).location, length: length) : nil
        needsDisplay = true
    }

    public func unmarkText() {
        markedTextRange = nil
        needsDisplay = true
    }

    public func markedRange() -> NSRange { markedTextRange ?? NSRange(location: NSNotFound, length: 0) }

    public func hasMarkedText() -> Bool { markedTextRange != nil }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let range = clamp(range, to: textStorage.length)
        actualRange?.pointee = range
        return textStorage.attributedSubstring(from: range)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .markedClauseSegment] }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let range = clamp(range, to: textStorage.length)
        let first = layoutRect(at: range.location)
        var rect = first
        if range.length > 0 {
            // Up to the end of the first screen row.
            let end = min(range.upperBound, layout.screenLineBoundary(from: range.location, forward: true))
            let last = layoutRect(at: max(range.location, end))
            rect.size.width = max(last.minX - first.minX, 1)
            actualRange?.pointee = NSRange(location: range.location, length: end - range.location)
        } else {
            rect.size.width = 0
            actualRange?.pointee = range
        }
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return NSNotFound }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return insertionIndex(at: local)
    }

    // MARK: Accessibility

    open override func isAccessibilityElement() -> Bool { true }
    open override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    open override func accessibilityValue() -> Any? { string }
    open override func accessibilityNumberOfCharacters() -> Int { textStorage.length }
    open override func accessibilitySelectedText() -> String? { textStorage.attributedSubstring(from: selectedRange()).string }
    open override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }
    open override func setAccessibilitySelectedTextRange(_ range: NSRange) { setSelectedRange(range) }
    open override func accessibilityInsertionPointLineNumber() -> Int { layout.line(containing: selectedRange().location) }
    open override func accessibilityLine(for index: Int) -> Int { layout.line(containing: max(0, min(index, textStorage.length))) }

    open override func accessibilityRange(forLine line: Int) -> NSRange {
        guard line >= 0, line < layout.lineCount else { return NSRange(location: NSNotFound, length: 0) }
        let end = line + 1 < layout.lineCount ? layout.starts[line + 1] : textStorage.length
        return NSRange(location: layout.starts[line], length: end - layout.starts[line])
    }

    open override func accessibilityVisibleCharacterRange() -> NSRange {
        let visible = visibleRect
        let start = characterIndex(at: CGPoint(x: 0, y: visible.minY))
        let end = layout.lineEnd(layout.line(containing: characterIndex(at: CGPoint(x: visible.maxX, y: visible.maxY))))
        return NSRange(location: start, length: max(0, end - start))
    }

    open override func accessibilityString(for range: NSRange) -> String? {
        textStorage.attributedSubstring(from: clamp(range, to: textStorage.length)).string
    }

    open override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        textStorage.attributedSubstring(from: clamp(range, to: textStorage.length))
    }

    open override func accessibilityFrame(for range: NSRange) -> NSRect {
        let range = clamp(range, to: textStorage.length)
        var rect = layoutRect(at: range.location)
        if range.length > 0 { rect = rect.union(layoutRect(at: max(range.location, range.upperBound - 1))) }
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    open override func accessibilityRange(for point: NSPoint) -> NSRange {
        let index = characterIndex(for: point)
        guard index != NSNotFound, index < textStorage.length else { return NSRange(location: index, length: 0) }
        return textStorage.mutableString.rangeOfComposedCharacterSequence(at: index)
    }
}

// MARK: - VimEngineDelegate

extension VimTextView: VimEngineDelegate {
    public func vimEngineWillApplyEdits(_ engine: VimEngine) {
        syncSuppression += 1
        textStorage.beginEditing()
    }

    public func vimEngine(_ engine: VimEngine, replaceCharactersIn range: NSRange, with text: String) {
        // The engine owns the text: its edits apply even when not editable.
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text))
    }

    public func vimEngineDidApplyEdits(_ engine: VimEngine) {
        textStorage.endEditing()
        syncSuppression -= 1
        searchArea = nil
        textDidChange()
    }

    public func vimEngine(_ engine: VimEngine, setSelections selections: [VimSelection], primary: Int) {
        var ranges = selections.map(\.range)
        if ranges.indices.contains(primary), primary != 0 { ranges.swapAt(0, primary) }
        selectionAnchor = nil
        showSelection(ranges)
        updateCursor()
    }

    public func vimEngineDidChangeStatus(_ engine: VimEngine) {
        updateCursor()
        onStatusChange?(engine.status)
    }

    public func vimEngineDidRequestSave(_ engine: VimEngine) { onSave?() }

    public func vimEngine(_ engine: VimEngine, didRun command: VimExCommand) { onExCommand?(command) }

    public func vimEngineDidRequestFocus(_ engine: VimEngine) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    public func vimEngineSearchHighlightDidChange(_ engine: VimEngine) {
        searchArea = nil
        needsDisplay = true
    }

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
        scrollToVisible(layoutRect(at: offset).insetBy(dx: 0, dy: -margin))
    }

    public func vimEngine(_ engine: VimEngine, verticalMoveFrom offset: Int, forward: Bool, byPage: Bool, goalX: CGFloat?) -> Int? {
        let rect = layoutRect(at: offset)
        // A page is the visible height less half a line, as in CodeMirror.
        let step = byPage ? max(visibleRect.height - lineHeight / 2, lineHeight) : rect.height
        let y = forward ? rect.midY + step : rect.midY - step
        if y < textOrigin.y { return 0 }
        let index = characterIndex(at: NSPoint(x: (goalX ?? rect.minX) + 1, y: y))
        return min(max(index, 0), textStorage.length)
    }

    public func vimEngine(_ engine: VimEngine, screenLineBoundaryFrom offset: Int, forward: Bool) -> Int? {
        layout.screenLineBoundary(from: offset, forward: forward)
    }

    public func vimEngineLineHeight(_ engine: VimEngine) -> CGFloat? { lineHeight }

    public func vimEngineFoldsDidChange(_ engine: VimEngine) { applyFolds() }

    public func vimEngine(_ engine: VimEngine, tokenTypeAt offset: Int) -> VimTokenType? {
        if let tokenTypeProvider { return tokenTypeProvider(offset) }
        return VimTokenType.at(offset - 1, in: textStorage)
    }
}
#endif
