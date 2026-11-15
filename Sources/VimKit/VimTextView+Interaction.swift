#if os(macOS)
import AppKit

/// What `NSTextView` gives for free and ``VimTextView`` implements itself:
/// the Services menu, dragging text in and out, and Look Up.
extension VimTextView: @preconcurrency NSServicesMenuRequestor, NSDraggingSource {
    // MARK: Services

    private static var servicesRegistered = false

    /// Tells AppKit this app's text views send and take plain text (once).
    static func registerServices() {
        guard !servicesRegistered else { return }
        servicesRegistered = true
        NSApp?.registerServicesMenuSendTypes([.string], returnTypes: [.string])
    }

    open override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                      returnType: NSPasteboard.PasteboardType?) -> Any? {
        let canSend = sendType == nil || (sendType == .string && selectedRange().length > 0)
        let canReturn = returnType == nil || (returnType == .string && isEditable)
        if canSend, canReturn, sendType != nil || returnType != nil { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    public func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string), selectedRange().length > 0 else { return false }
        pboard.clearContents()
        return pboard.setString(textStorage.attributedSubstring(from: selectedRange()).string, forType: .string)
    }

    public func readSelection(from pboard: NSPasteboard) -> Bool {
        guard isEditable, let text = pboard.string(forType: .string) else { return false }
        replace(selectedRange(), with: text)
        return true
    }

    // MARK: Dragging text out

    /// A click inside the selection that turns into a drag drags the text;
    /// one that doesn't puts the caret there. Returns false for other clicks.
    func beginDraggingSelection(with event: NSEvent, at point: CGPoint) -> Bool {
        let selection = selectedRange()
        guard selection.length > 0 else { return false }
        guard rowRects(for: selection).contains(where: { $0.contains(point) }) else { return false }
        let index = insertionIndex(at: point)
        guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { return true }
        if next.type == .leftMouseUp {
            setSelectedRange(NSRange(location: showsBlockCursor ? characterIndex(at: point) : index, length: 0))
            return true
        }
        let text = textStorage.attributedSubstring(from: selection).string
        let item = NSDraggingItem(pasteboardWriter: text as NSString)
        let rects = rowRects(for: selection)
        let frame = rects.dropFirst().reduce(rects.first ?? CGRect(origin: point, size: .zero)) { $0.union($1) }
        item.setDraggingFrame(frame, contents: dragImage(of: selection, in: frame))
        draggedRange = selection
        beginDraggingSession(with: [item], event: event, source: self)
        return true
    }

    /// The selection as it looks on screen, for the drag.
    private func dragImage(of range: NSRange, in frame: CGRect) -> NSImage {
        NSImage(size: frame.size, flipped: true) { [weak self] _ in
            guard let self, let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: -frame.minX, y: -frame.minY)
            self.drawCharacters(in: range)
            return true
        }
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication && isEditable ? [.copy, .move] : .copy
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedRange = nil
    }

    // MARK: Dropping text in

    open override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    open override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isEditable, droppedText(from: sender.draggingPasteboard) != nil else { return [] }
        let index = insertionIndex(at: convert(sender.draggingLocation, from: nil))
        if dropIndex != index {
            for old in [dropIndex, index].compactMap({ $0 }) { setNeedsDisplay(layoutRect(at: old).insetBy(dx: -3, dy: -1)) }
            dropIndex = index
        }
        autoscroll(with: NSApp.currentEvent ?? NSEvent())
        let moves = (sender.draggingSource as AnyObject?) === self && !NSEvent.modifierFlags.contains(.option)
        return moves ? .move : .copy
    }

    open override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDropIndex()
    }

    open override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clearDropIndex() }
        guard isEditable, let text = droppedText(from: sender.draggingPasteboard) else { return false }
        let index = insertionIndex(at: convert(sender.draggingLocation, from: nil))
        let moving = (sender.draggingSource as AnyObject?) === self && !NSEvent.modifierFlags.contains(.option)
        window?.makeFirstResponder(self)
        return drop(text, at: index, moving: moving ? draggedRange : nil)
    }

    /// Inserts dropped text at `index`; a move within the view first removes
    /// the dragged range. The dropped text ends up selected.
    @discardableResult
    func drop(_ text: String, at index: Int, moving source: NSRange?) -> Bool {
        var index = index
        if let source {
            if NSLocationInRange(index, source) || index == source.upperBound { return false }
            replace(source, with: "", notify: false)
            if index > source.location { index -= source.length }
        }
        replace(NSRange(location: index, length: 0), with: text, notify: false)
        setSelectedRange(NSRange(location: index, length: (text as NSString).length))
        textDidChange()
        return true
    }

    private func clearDropIndex() {
        if let dropIndex { setNeedsDisplay(layoutRect(at: dropIndex).insetBy(dx: -3, dy: -1)) }
        dropIndex = nil
    }

    /// Text from the pasteboard, or the paths of dropped files, one per line.
    private func droppedText(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map(\.path).joined(separator: "\n")
        }
        return pasteboard.string(forType: .string)
    }

    // MARK: Look Up

    /// Force click or three-finger tap: the dictionary for the word there.
    open override func quickLook(with event: NSEvent) {
        lookUp(at: characterIndex(at: convert(event.locationInWindow, from: nil)))
    }

    /// The word Look Up shows for `offset`: the selection if it contains
    /// `offset`, otherwise the word there.
    func lookUpRange(at offset: Int) -> NSRange? {
        let selection = selectedRange()
        if selection.length > 0, NSLocationInRange(offset, selection) { return selection }
        guard offset < textStorage.length else { return nil }
        let word = textStorage.doubleClick(at: offset)
        let text = textStorage.attributedSubstring(from: word).string
        return word.length > 0 && text.contains(where: { $0.isLetter }) ? word : nil
    }

    func lookUp(at offset: Int) {
        guard let range = lookUpRange(at: offset) else { return }
        let word = NSAttributedString(string: textStorage.attributedSubstring(from: range).string,
                                      attributes: [.font: font, .foregroundColor: textColor])
        let rect = layoutRect(at: range.location)
        showDefinition(for: word, at: CGPoint(x: rect.minX, y: rect.minY + layout.baseline))
    }

    @objc func lookUpFromMenu(_ item: NSMenuItem) {
        guard let range = (item.representedObject as? NSValue)?.rangeValue else { return }
        lookUp(at: range.location)
    }
}
#endif
