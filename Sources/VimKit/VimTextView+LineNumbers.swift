#if os(macOS)
import AppKit
import VimCore

/// The line number column: a vertical ruler of the enclosing scroll view,
/// so it stays put when the text scrolls sideways.
final class VimLineNumberRuler: NSRulerView {
    weak var textView: VimTextView?

    init(textView: VimTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // Views don't clip their drawing by default (macOS 14): the
        // background must not cover the text next to the ruler.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { textView?.drawsBackground ?? false }

    override func draw(_ dirtyRect: NSRect) {
        textView?.drawLineNumbers(in: dirtyRect, ruler: self)
    }

    override func mouseDown(with event: NSEvent) {
        textView?.selectLines(from: event, in: self)
    }
}

extension VimTextView {
    /// Shows the ruler for ``lineNumbers`` (or hides it) and sizes it.
    func updateLineNumberRuler() {
        guard let scrollView = enclosingScrollView else { return }
        guard lineNumbers != .off else {
            if lineNumberRuler != nil, scrollView.rulersVisible {
                retile(scrollView) { scrollView.rulersVisible = false }
            }
            return
        }
        let ruler: VimLineNumberRuler
        if let existing = lineNumberRuler, existing.scrollView === scrollView {
            ruler = existing
        } else {
            ruler = VimLineNumberRuler(textView: self, scrollView: scrollView)
            lineNumberRuler = ruler
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
        }
        let thickness = lineNumberWidth()
        if ruler.ruleThickness != thickness || !scrollView.rulersVisible {
            retile(scrollView) {
                ruler.ruleThickness = thickness
                scrollView.rulersVisible = true
            }
        }
        ruler.needsDisplay = true
    }

    /// Changes the ruler; the scroll view then insets the clip view on the
    /// left. The text keeps its place and width.
    private func retile(_ scrollView: NSScrollView, _ change: () -> Void) {
        let clip = scrollView.contentView
        let left = clip.bounds.minX + clip.contentInsets.left
        change()
        scrollView.tile()
        updateFrameSize()
        let origin = CGPoint(x: left - clip.contentInsets.left, y: clip.bounds.minY)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Width for the largest line number: at least `numberwidth` - 1 digits,
    /// half a digit before, one after (Vim's separating space).
    func lineNumberWidth() -> CGFloat {
        let option = isVimEnabled ? vim.vimOption("numberwidth") : nil
        let width = (option as? NSNumber)?.intValue ?? (option as? String).flatMap { Int($0) } ?? 4
        let minimum = max(1, width - 1)
        let digits = max(minimum, String(layout.lineCount).count)
        return ceil((CGFloat(digits) + 1.5) * digitWidth)
    }

    private var digitWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// The text, its folds or its geometry changed.
    func lineNumbersDidChange() {
        guard lineNumbers != .off, let ruler = lineNumberRuler else { return }
        let thickness = lineNumberWidth()
        if ruler.ruleThickness != thickness, let scrollView = enclosingScrollView {
            retile(scrollView) { ruler.ruleThickness = thickness }
        }
        ruler.needsDisplay = true
    }

    /// The cursor moved: its line's number (and relative numbers) change.
    func lineNumbersCursorMoved() {
        guard lineNumbers != .off, let ruler = lineNumberRuler else { return }
        let line = layout.line(containing: min(numberedCursorOffset, textStorage.length))
        guard line != numberedCursorLine else { return }
        numberedCursorLine = line
        ruler.needsDisplay = true
    }

    /// Where the cursor is, for the current line number.
    var numberedCursorOffset: Int {
        isVimEnabled ? vim.status.cursorOffset : selectedRange().location
    }

    /// The engine's `number` / `relativenumber` changed (`:set nu`).
    func lineNumberOptionsChanged() {
        guard isVimEnabled else { return }
        let mode = VimLineNumbers(number: vim.vimOption("number") as? Bool ?? false,
                                  relative: vim.vimOption("relativenumber") as? Bool ?? false)
        if mode != lineNumbers { setLineNumbers(mode, updatingEngine: false) } else { lineNumbersDidChange() }
    }

    func setLineNumbers(_ mode: VimLineNumbers, updatingEngine: Bool) {
        lineNumberMode = mode
        if updatingEngine, isVimEnabled {
            vim.setVimOption("number", mode.showsNumber)
            vim.setVimOption("relativenumber", mode.showsRelative)
        }
        numberedCursorLine = -1
        updateLineNumberRuler()
    }

    func drawLineNumbers(in dirtyRect: NSRect, ruler: VimLineNumberRuler) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dirtyRect = dirtyRect.intersection(ruler.bounds)
        if drawsBackground {
            backgroundColor.setFill()
            dirtyRect.fill()
        }
        let origin = textOrigin
        let top = ruler.convert(NSPoint(x: 0, y: dirtyRect.minY), to: self).y - origin.y
        let bottom = ruler.convert(NSPoint(x: 0, y: dirtyRect.maxY), to: self).y - origin.y
        let lines = layout.visibleLines(from: top - layout.rowHeight, to: bottom + layout.rowHeight)
        guard !lines.isEmpty else { return }
        let cursorLine = layout.line(containing: min(numberedCursorOffset, textStorage.length))
        numberedCursorLine = cursorLine
        let mode = lineNumbers
        guard mode != .off else { return }
        let digit = digitWidth
        let right = ruler.bounds.width - digit
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: lineNumberColor]
        let bright: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: currentLineNumberColor]
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (line, y) in lines {
            // Vim marks the cursor line's number only with 'cursorline'.
            let current = line == cursorLine && highlightsCursorLineNumber
            let label = lineNumberLabel(line, cursorLine: cursorLine)
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: current ? bright : dim))
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            // Hybrid numbers show the cursor line's own number on the left, as Vim does.
            let x = mode == .hybrid && line == cursorLine ? digit / 2 : right - width
            let rowTop = ruler.convert(NSPoint(x: 0, y: origin.y + y), from: self).y
            context.textPosition = CGPoint(x: x, y: rowTop + layout.baseline)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }

    // MARK: Cursor line

    var highlightsCursorLineNumber: Bool { cursorLineEnabled && cursorLineParts.contains("number") }

    /// The engine's `cursorline` / `cursorlineopt` changed.
    func cursorLineOptionsChanged() {
        guard isVimEnabled else { return }
        cursorLineEnabled = vim.vimOption("cursorline") as? Bool ?? false
        let opt = (vim.vimOption("cursorlineopt") as? String) ?? "both"
        var parts = Set(opt.split(separator: ",").map(String.init))
        if parts.remove("both") != nil { parts.formUnion(["line", "number"]) }
        cursorLineParts = parts
        cursorLineSettingsChanged()
    }

    func cursorLineSettingsChanged() {
        updateCursorLineRect()
        lineNumberRuler?.needsDisplay = true
    }

    /// Where the cursor line highlight goes: the whole width of the cursor's
    /// line (all its wrapped rows), or only its row with "screenline".
    func updateCursorLineRect() {
        var rect: CGRect?
        if cursorLineEnabled, !cursorLineParts.isDisjoint(with: ["line", "screenline"]) {
            let offset = max(0, min(numberedCursorOffset, textStorage.length))
            let row = layoutRect(at: offset)
            let line = layout.line(containing: offset)
            if cursorLineParts.contains("screenline") || layout.isHidden(line) {
                rect = CGRect(x: 0, y: row.minY, width: bounds.width, height: row.height)
            } else {
                rect = CGRect(x: 0, y: textOrigin.y + layout.y(ofLine: line), width: bounds.width,
                              height: CGFloat(layout.visibleRows(ofLine: line)) * lineHeight)
            }
        }
        guard rect != cursorLineRect else { return }
        if let old = cursorLineRect { setNeedsDisplay(old) }
        if let rect { setNeedsDisplay(rect) }
        cursorLineRect = rect
    }

    /// The number shown for `line`. Relative numbers count lines a closed
    /// fold hides as one, as j and k do.
    func lineNumberLabel(_ line: Int, cursorLine: Int) -> String {
        func shownBefore(_ line: Int) -> Int {
            var count = line
            for range in layout.hiddenLines where range.lowerBound < line {
                count -= min(range.upperBound + 1, line) - range.lowerBound
            }
            return count
        }
        switch lineNumbers {
        case .off: return ""
        case .absolute: return String(line + 1)
        case .relative: return String(abs(shownBefore(line) - shownBefore(cursorLine)))
        case .hybrid: return line == cursorLine ? String(line + 1) : String(abs(shownBefore(line) - shownBefore(cursorLine)))
        }
    }

    /// A click in the number column puts the cursor on that line; a drag
    /// selects whole lines.
    func selectLines(from event: NSEvent, in ruler: VimLineNumberRuler) {
        window?.makeFirstResponder(self)
        let anchor = numberedLine(at: ruler.convert(event.locationInWindow, from: nil), in: ruler)
        selectLines(anchor, anchor, extending: false)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            autoscroll(with: next)
            selectLines(anchor, numberedLine(at: ruler.convert(next.locationInWindow, from: nil), in: ruler), extending: true)
        }
    }

    /// The line whose number is at `point` (ruler coordinates).
    func numberedLine(at point: NSPoint, in ruler: VimLineNumberRuler) -> Int {
        let y = ruler.convert(point, to: self).y
        return layout.line(containing: characterIndex(at: NSPoint(x: textOrigin.x, y: y)))
    }

    /// The cursor at the start of `anchor`, or lines `anchor` through `line` selected.
    func selectLines(_ anchor: Int, _ line: Int, extending: Bool) {
        guard extending else {
            setSelectedRange(NSRange(location: layout.starts[anchor], length: 0))
            return
        }
        let first = min(anchor, line), last = max(anchor, line)
        let end = last + 1 < layout.lineCount ? layout.starts[last + 1] : textStorage.length
        setSelectedRange(NSRange(location: layout.starts[first], length: end - layout.starts[first]))
    }
}
#endif
