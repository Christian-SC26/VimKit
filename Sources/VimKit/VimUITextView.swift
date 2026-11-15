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

    /// Delay before a held key starts repeating, and the interval between repeats.
    public var keyRepeatDelay: Duration = .milliseconds(400)
    public var keyRepeatInterval: Duration = .milliseconds(40)

    private var syncSuppression = 0
    /// Edits made by UIKit (typing, dictation, paste) not yet sent to vim.
    private var pendingEdits: [(range: NSRange, text: String)] = []
    private var pendingSelection = false
    private var flushScheduled = false
    private let blockCursor = UIView()
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
        return vim.handle(key)
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

    open override func layoutSubviews() {
        super.layoutSubviews()
        if subviews.last !== blockCursor { bringSubviewToFront(blockCursor) }
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
        blockCursor.backgroundColor = caretColor.withAlphaComponent(0.45)
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

    private func updateSearchHighlight() {
        geometry.setHighlights(isVimEnabled ? vim.searchMatches(limit: 5_000) : [], color: searchHighlightColor)
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
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
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
}
#endif
