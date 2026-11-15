#if canImport(UIKit) && !os(watchOS)
import UIKit
@_exported import VimCore

/// A `UITextView` with Vim keybindings, for iPad with a hardware keyboard
/// (and iPhone).
///
/// Hardware key presses go to ``vim`` first; whatever vim does not consume
/// (typing in insert mode, Command shortcuts) reaches the text view as usual.
/// Holding a key repeats it. With the on-screen keyboard, characters typed
/// in normal or visual mode run as Vim commands.
///
/// iPad keyboards often have no Escape key: `Ctrl-[` works, or map Caps Lock
/// to Escape in Settings › General › Keyboard › Hardware Keyboard › Modifier Keys.
@MainActor
open class VimUITextView: UITextView {
    /// The engine driving this view.
    public let vim: VimEngine

    /// Turns Vim behaviour on or off. Off, the view is a plain `UITextView`.
    public var isVimEnabled: Bool = true {
        didSet {
            guard isVimEnabled != oldValue else { return }
            if isVimEnabled {
                vim.setText(text ?? "")
                forwardSelection()
            }
            applyFolds()
            updateCursorAppearance()
            updateSearchHighlight()
        }
    }

    /// Called whenever mode, pending keys, command line or messages change.
    public var onStatusChange: ((VimStatus) -> Void)?
    /// Called for `:w`.
    public var onSave: (() -> Void)?
    /// Called for ex commands defined with `vim.defineEx` without a handler.
    public var onExCommand: ((VimExCommand) -> Void)?

    /// Color of the insertion point in insert mode and of the block cursor.
    public var caretColor: UIColor = .tintColor {
        didSet { updateCursorAppearance() }
    }
    public var searchHighlightColor: UIColor = .systemYellow.withAlphaComponent(0.35) {
        didSet { updateSearchHighlight() }
    }

    /// Tells vim whether the character before an offset is in a string or a
    /// comment (for `%` and `=`). When nil, the `.vimTokenType` text attribute is used.
    public var tokenTypeProvider: ((Int) -> VimTokenType?)?

    /// Delay before a held key starts repeating, and the interval between repeats.
    public var keyRepeatDelay: Duration = .milliseconds(400)
    public var keyRepeatInterval: Duration = .milliseconds(40)

    private var syncSuppression = 0
    /// Edits made by UIKit (typing, dictation, paste) not yet sent to vim.
    private var pendingEdits: [(range: NSRange, text: String)] = []
    private var pendingSelection = false
    private var flushScheduled = false
    private let blockCursor = UIView()
    private var foldLabels: [UILabel] = []
    private var foldLabelWidth: CGFloat = -1
    private let geometry = TextKit2Geometry()
    private var consumedPresses: Set<ObjectIdentifier> = []
    private var repeatingPress: ObjectIdentifier?
    private var repeatTask: Task<Void, Never>?

    // MARK: Initialization

    /// Creates a TextKit 2 text view.
    public init(frame: CGRect = .zero, options: VimOptions = VimOptions(), runtime: VimRuntime? = nil) {
        vim = VimEngine(options: options, runtime: runtime)
        super.init(frame: frame, textContainer: nil)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        vim = VimEngine()
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        vim.delegate = self
        geometry.layoutManager = textLayoutManager
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        inlinePredictionType = .no
        font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        blockCursor.isUserInteractionEnabled = false
        blockCursor.isHidden = true
        addSubview(blockCursor)
        // Folded lines are left out of layout by the content storage delegate.
        if let storage = textLayoutManager?.textContentManager as? NSTextContentStorage, storage.delegate == nil {
            storage.delegate = self
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(vimTextStorageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: textStorage
        )
        vim.setText(text ?? "")
        updateCursorAppearance()
    }

    // MARK: Keyboard

    /// Sends one key to vim. Returns true if vim consumed it.
    @discardableResult
    public func handleVimKey(_ key: VimKeyEvent) -> Bool {
        guard isVimEnabled, markedTextRange == nil else { return false }
        flushPendingEdits()
        return coalescingCursorUpdates { vim.handle(key) }
    }

    open override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let uiKey = press.key, let key = VimKeyEvent(uiKey), handleVimKey(key) {
                consumedPresses.insert(ObjectIdentifier(press))
                startRepeating(key, press: press)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    open override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !consumedPresses.contains(ObjectIdentifier($0)) }
        if !unhandled.isEmpty { super.pressesChanged(unhandled, with: event) }
    }

    open override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = finishPresses(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    open override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = finishPresses(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    /// Stops repeating and forgets consumed presses; returns the presses UIKit should see.
    private func finishPresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            let id = ObjectIdentifier(press)
            if id == repeatingPress { stopRepeating() }
            if consumedPresses.remove(id) == nil { unhandled.insert(press) }
        }
        return unhandled
    }

    /// UIKit does not repeat `pressesBegan` while a key is held, so consumed
    /// keys repeat here.
    private func startRepeating(_ key: VimKeyEvent, press: UIPress) {
        stopRepeating()
        repeatingPress = ObjectIdentifier(press)
        let delay = keyRepeatDelay, interval = keyRepeatInterval
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                guard let self else { return }
                if !self.handleVimKey(key), key.key.count == 1, !key.control, !key.command {
                    // The command switched to insert mode (e.g. a held `i`): keep typing.
                    self.insertText(key.key)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
        repeatingPress = nil
    }

    /// Text from the on-screen keyboard. In normal and visual mode the
    /// characters are Vim commands; in insert mode they are typed.
    open override func insertText(_ text: String) {
        if isVimEnabled, markedTextRange == nil, !vim.mode.isInsertLike {
            for character in text {
                handleVimKey(VimKeyEvent(key: character == "\n" ? VimKeyEvent.enter : String(character)))
            }
            return
        }
        super.insertText(text)
        flushPendingEdits()
    }

    open override func deleteBackward() {
        if isVimEnabled, markedTextRange == nil, !vim.mode.isInsertLike {
            handleVimKey(VimKeyEvent(key: VimKeyEvent.backspace))
            return
        }
        super.deleteBackward()
        flushPendingEdits()
    }

    open override var keyCommands: [UIKeyCommand]? {
        guard isVimEnabled else { return super.keyCommands }
        let undo = UIKeyCommand(title: "Undo", action: #selector(vimUndo(_:)), input: "z", modifierFlags: .command)
        let redo = UIKeyCommand(title: "Redo", action: #selector(vimRedo(_:)), input: "z", modifierFlags: [.command, .shift])
        for command in [undo, redo] { command.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + [undo, redo]
    }

    @objc open func vimUndo(_ sender: Any?) { vim.undo() }
    @objc open func vimRedo(_ sender: Any?) { vim.redo() }

    /// Vim keeps its own history; UIKit's would undo behind its back.
    open override var undoManager: UndoManager? {
        isVimEnabled ? nil : super.undoManager
    }

    // MARK: View → engine

    open override var text: String! {
        get { super.text }
        set {
            syncSuppression += 1
            super.text = newValue
            syncSuppression -= 1
            if isVimEnabled { vim.setText(newValue ?? "") }
            updateBlockCursor()
        }
    }

    open override var attributedText: NSAttributedString! {
        get { super.attributedText }
        set {
            syncSuppression += 1
            super.attributedText = newValue
            syncSuppression -= 1
            if isVimEnabled { vim.setText(newValue?.string ?? "") }
            updateBlockCursor()
        }
    }

    open override var selectedTextRange: UITextRange? {
        get { super.selectedTextRange }
        set {
            super.selectedTextRange = newValue
            selectionChangedByUIKit()
        }
    }

    open override var selectedRange: NSRange {
        get { super.selectedRange }
        set {
            super.selectedRange = newValue
            selectionChangedByUIKit()
        }
    }

    private func selectionChangedByUIKit() {
        guard isVimEnabled, syncSuppression == 0 else { return }
        if !pendingEdits.isEmpty {
            pendingSelection = true // sent after the edit it belongs to
            return
        }
        forwardSelection()
    }

    @objc private func vimTextStorageDidProcessEditing(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage else { return }
        geometry.noteEdit(at: storage.editedRange.location)
        guard isVimEnabled, syncSuppression == 0, storage.editedMask.contains(.editedCharacters) else { return }
        let edited = storage.editedRange
        let replaced = NSRange(location: edited.location, length: edited.length - storage.changeInLength)
        pendingEdits.append((replaced, (storage.string as NSString).substring(with: edited)))
        if !flushScheduled {
            // Edits made directly to the text storage reach vim on the next turn.
            flushScheduled = true
            Task { [weak self] in self?.flushPendingEdits() }
        }
    }

    private func flushPendingEdits() {
        flushScheduled = false
        guard !pendingEdits.isEmpty else { return }
        let edits = pendingEdits
        pendingEdits = []
        for edit in edits { vim.replaceCharacters(in: edit.range, with: edit.text) }
        if pendingSelection { pendingSelection = false }
        forwardSelection()
    }

    private func forwardSelection() {
        vim.setSelections([VimSelection(selectedRange)])
        updateBlockCursor()
    }

    /// Re-reads the text into the engine. Clears vim's undo history.
    public func resyncEngine() {
        pendingEdits = []
        vim.setText(text ?? "")
        forwardSelection()
    }

    // MARK: Cursor

    open override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateCursorAppearance()
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        if subviews.last !== blockCursor { bringSubviewToFront(blockCursor) }
        if !foldLabels.isEmpty, bounds.width != foldLabelWidth { updateFoldLabels() }
        updateBlockCursor()
    }

    private var showsBlockCursor: Bool {
        isVimEnabled && !vim.mode.isInsertLike
    }

    private func updateCursorAppearance() {
        // The system caret takes the tint color. Hide it in normal mode, where
        // the block cursor is shown; keep the tint in visual mode for the selection.
        let hidesCaret = showsBlockCursor && !vim.mode.isVisual
        let tint = hidesCaret ? UIColor.clear : caretColor
        if tintColor != tint { tintColor = tint }
        // The character under the cursor is painted inverted; the box is only
        // drawn where there is no character (line ends).
        blockCursor.backgroundColor = resolvedCaretColor
        updateBlockCursor()
    }

    /// `caretColor`, with `.tintColor` taken from the superview: this view's
    /// own tint is cleared in normal mode to hide the system caret.
    private var resolvedCaretColor: UIColor {
        caretColor == .tintColor ? (superview?.tintColor ?? .systemBlue) : caretColor
    }

    /// Where the block cursor is drawn (content coordinates), or nil when hidden.
    private(set) var blockCursorFrame: CGRect?

    /// Whether the cursor is drawn as a box (where there is no character to invert).
    var showsCursorBox: Bool { !blockCursor.isHidden }

    /// Text color of the character under the block cursor.
    private var cursorTextColor: UIColor {
        if let backgroundColor, backgroundColor.cgColor.alpha > 0 { return backgroundColor }
        return .systemBackground
    }

    /// Nesting depth of ``coalescingCursorUpdates(_:)``.
    private var cursorUpdatesDeferred = 0
    private var blockCursorNeedsUpdate = false

    /// Runs `body` with block cursor updates folded into one at the end. One
    /// key can change mode and selection thousands of times (`:%norm`, macros),
    /// and every update lays out text up to the cursor.
    private func coalescingCursorUpdates<T>(_ body: () -> T) -> T {
        cursorUpdatesDeferred += 1
        defer {
            cursorUpdatesDeferred -= 1
            if cursorUpdatesDeferred == 0, blockCursorNeedsUpdate {
                blockCursorNeedsUpdate = false
                updateBlockCursor()
            }
        }
        return body()
    }

    private func updateBlockCursor() {
        if cursorUpdatesDeferred > 0 {
            blockCursorNeedsUpdate = true
            return
        }
        let offset = vim.status.cursorOffset
        let previous = blockCursorFrame
        guard showsBlockCursor, let rect = characterRect(at: offset) else {
            blockCursorFrame = nil
            blockCursor.isHidden = true
            geometry.setCursor(nil, background: resolvedCaretColor, foreground: cursorTextColor)
            if let previous { redrawText(in: previous) }
            return
        }
        blockCursorFrame = rect
        redrawText(in: previous.map { $0.union(rect) } ?? rect)
        let text = (text ?? "") as NSString
        if offset < text.length, ![0x0A, 0x0D].contains(text.character(at: offset)) {
            geometry.setCursor(text.rangeOfComposedCharacterSequence(at: offset), background: resolvedCaretColor, foreground: cursorTextColor)
            blockCursor.isHidden = true
        } else {
            geometry.setCursor(nil, background: resolvedCaretColor, foreground: cursorTextColor)
            blockCursor.frame = rect.integral
            blockCursor.isHidden = false
        }
    }

    // MARK: Geometry

    private var effectiveFont: UIFont {
        font ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
    }

    private var lineHeight: CGFloat { effectiveFont.lineHeight }

    private var spaceWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: effectiveFont]).width
    }

    private var containerOrigin: CGPoint {
        CGPoint(x: textContainerInset.left, y: textContainerInset.top)
    }

    /// The visible part of the content, excluding content insets.
    private var visibleContentRect: CGRect {
        bounds.inset(by: adjustedContentInset)
    }

    /// Rectangle of the character at `offset` in content coordinates. At a
    /// line end (or the end of the text) it is a space-wide box.
    public func characterRect(at offset: Int) -> CGRect? {
        let origin = containerOrigin
        return geometry.characterRect(at: offset, text: (text ?? "") as NSString, spaceWidth: spaceWidth, lineHeight: lineHeight)?
            .offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Offset of the character at `point` (content coordinates), laying out
    /// that part of the text first.
    public func characterIndex(at point: CGPoint) -> Int {
        let origin = containerOrigin
        return geometry.characterIndex(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y), text: (text ?? "") as NSString)
    }

    /// TextKit 2 does not redraw text when only rendering attributes change
    /// (cursor, search highlight), so mark the text under `rect` for display.
    private func redrawText(in rect: CGRect) {
        func mark(_ view: UIView) {
            for subview in view.subviews where subview !== blockCursor && !foldLabels.contains(where: { $0 === subview }) {
                let local = subview.convert(rect, from: self)
                guard subview.bounds.intersects(local) else { continue }
                subview.setNeedsDisplay(local)
                mark(subview)
            }
        }
        mark(self)
    }

    // MARK: Folding

    private func applyFolds() {
        geometry.setHidden(isVimEnabled ? vim.folds.map(\.hiddenRange) : [])
        updateFoldLabels()
        updateBlockCursor()
    }

    /// A "⋯ N lines" label after each closed fold's header line.
    private func updateFoldLabels() {
        let folds = isVimEnabled ? vim.folds : []
        foldLabelWidth = bounds.width
        while foldLabels.count > folds.count { foldLabels.removeLast().removeFromSuperview() }
        while foldLabels.count < folds.count {
            let label = UILabel()
            label.backgroundColor = .tertiarySystemFill
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.layer.cornerRadius = 4
            label.clipsToBounds = true
            insertSubview(label, belowSubview: blockCursor)
            foldLabels.append(label)
        }
        let labelFont = UIFont.monospacedSystemFont(ofSize: effectiveFont.pointSize * 0.85, weight: .regular)
        for (fold, label) in zip(folds, foldLabels) {
            guard let header = characterRect(at: fold.hiddenRange.location - 1) else {
                label.isHidden = true
                continue
            }
            label.font = labelFont
            label.text = fold.placeholder
            let fitted = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: header.height))
            let size = CGSize(width: fitted.width + 10, height: min(fitted.height + 2, header.height))
            label.frame = CGRect(x: header.maxX + spaceWidth, y: header.midY - size.height / 2, width: size.width, height: size.height).integral
            label.isHidden = false
        }
    }

    /// Placeholders of the closed folds, for tests.
    var foldPlaceholders: [(text: String, frame: CGRect)] {
        foldLabels.filter { !$0.isHidden }.map { ($0.text ?? "", $0.frame) }
    }

    private func updateSearchHighlight() {
        geometry.setHighlights(isVimEnabled ? vim.searchMatches(limit: 5_000) : [], color: searchHighlightColor)
        redrawText(in: visibleContentRect)
    }

    private func notifyTextChanged() {
        delegate?.textViewDidChange?(self)
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: self)
    }
}

// MARK: - VimEngineDelegate

extension VimUITextView: VimEngineDelegate {
    public func vimEngineWillApplyEdits(_ engine: VimEngine) {
        syncSuppression += 1
        textStorage.beginEditing()
    }

    public func vimEngine(_ engine: VimEngine, replaceCharactersIn range: NSRange, with text: String) {
        var attributes = typingAttributes
        attributes[.vimTokenType] = nil
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
    }

    public func vimEngineDidApplyEdits(_ engine: VimEngine) {
        textStorage.endEditing()
        syncSuppression -= 1
        notifyTextChanged()
    }

    public func vimEngine(_ engine: VimEngine, setSelections selections: [VimSelection], primary: Int) {
        // UITextView has one selection; use the primary range.
        guard let selection = selections.indices.contains(primary) ? selections[primary] : selections.first else { return }
        let length = ((text ?? "") as NSString).length
        let start = max(0, min(selection.range.location, length))
        let end = max(start, min(selection.range.location + selection.range.length, length))
        syncSuppression += 1
        super.selectedRange = NSRange(location: start, length: end - start)
        syncSuppression -= 1
        updateBlockCursor()
    }

    public func vimEngineDidChangeStatus(_ engine: VimEngine) {
        updateCursorAppearance()
        onStatusChange?(engine.status)
    }

    public func vimEngineDidRequestSave(_ engine: VimEngine) { onSave?() }

    public func vimEngine(_ engine: VimEngine, didRun command: VimExCommand) { onExCommand?(command) }

    public func vimEngineDidRequestFocus(_ engine: VimEngine) {
        if !isFirstResponder { becomeFirstResponder() }
    }

    public func vimEngineSearchHighlightDidChange(_ engine: VimEngine) { updateSearchHighlight() }

    public func vimEngine(_ engine: VimEngine, rectForCharacterAt offset: Int) -> CGRect? {
        characterRect(at: offset)
    }

    public func vimEngine(_ engine: VimEngine, characterIndexAt point: CGPoint) -> Int? {
        characterIndex(at: point)
    }

    public func vimEngineScrollInfo(_ engine: VimEngine) -> VimScrollInfo? {
        VimScrollInfo(visibleRect: visibleContentRect, contentSize: contentSize)
    }

    public func vimEngine(_ engine: VimEngine, scrollToX x: CGFloat?, y: CGFloat?) {
        let inset = adjustedContentInset
        var offset = contentOffset
        if let x { offset.x = x - inset.left }
        if let y { offset.y = y - inset.top }
        let maxY = max(-inset.top, contentSize.height + inset.bottom - bounds.height)
        let maxX = max(-inset.left, contentSize.width + inset.right - bounds.width)
        offset.y = min(max(offset.y, -inset.top), maxY)
        offset.x = min(max(offset.x, -inset.left), maxX)
        setContentOffset(offset, animated: false)
    }

    public func vimEngine(_ engine: VimEngine, scrollCharacterToVisible offset: Int, margin: CGFloat) {
        guard let rect = characterRect(at: offset) else { return }
        // Make sure the content is tall enough to scroll there (TextKit 2 sizes it lazily).
        if rect.maxY + textContainerInset.bottom > contentSize.height { layoutIfNeeded() }
        var target = rect.insetBy(dx: 0, dy: -margin)
        // On the first or last line, also show the text container inset.
        if target.minY < textContainerInset.top + lineHeight {
            target = CGRect(x: target.minX, y: 0, width: target.width, height: target.maxY)
        }
        if target.maxY > contentSize.height - textContainerInset.bottom - lineHeight {
            target.size.height = max(target.height, contentSize.height - target.minY)
        }
        scrollRectToVisible(target, animated: false)
    }

    public func vimEngine(_ engine: VimEngine, verticalMoveFrom offset: Int, forward: Bool, byPage: Bool, goalX: CGFloat?) -> Int? {
        guard let rect = characterRect(at: offset) else { return nil }
        let length = ((text ?? "") as NSString).length
        // A page is the visible height less half a line, as in CodeMirror.
        let step = byPage ? max(visibleContentRect.height - lineHeight / 2, lineHeight) : rect.height
        let y = forward ? rect.midY + step : rect.midY - step
        if y < containerOrigin.y { return 0 }
        let index = characterIndex(at: CGPoint(x: (goalX ?? rect.minX) + 1, y: y))
        return min(max(index, 0), length)
    }

    public func vimEngine(_ engine: VimEngine, screenLineBoundaryFrom offset: Int, forward: Bool) -> Int? {
        geometry.screenLineBoundary(from: offset, forward: forward, text: (text ?? "") as NSString)
    }

    public func vimEngineLineHeight(_ engine: VimEngine) -> CGFloat? { lineHeight }

    public func vimEngineFoldsDidChange(_ engine: VimEngine) { applyFolds() }

    public func vimEngine(_ engine: VimEngine, tokenTypeAt offset: Int) -> VimTokenType? {
        if let tokenTypeProvider { return tokenTypeProvider(offset) }
        return VimTokenType.at(offset - 1, in: textStorage)
    }
}

// MARK: - Folding

extension VimUITextView: NSTextContentStorageDelegate {
    public nonisolated func textContentManager(
        _ textContentManager: NSTextContentManager,
        shouldEnumerate textElement: NSTextElement,
        options: NSTextContentManager.EnumerationOptions
    ) -> Bool {
        // Layout runs on the main thread.
        nonisolated(unsafe) let element = textElement
        return MainActor.assumeIsolated { !geometry.isHidden(element) }
    }
}
#endif
