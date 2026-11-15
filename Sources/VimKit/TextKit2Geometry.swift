#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// TextKit 2 geometry shared by ``VimTextView`` and ``VimUITextView``.
///
/// All rectangles and points are in text-container coordinates; the views add
/// their container origin (`textContainerOrigin` / `textContainerInset`).
@MainActor
final class TextKit2Geometry {
    weak var layoutManager: NSTextLayoutManager?

    /// Text before this offset has exact (not estimated) layout.
    private var exactLayoutEnd = 0
    private var exactLayoutWidth: CGFloat = -1

    private var content: NSTextContentManager? { layoutManager?.textContentManager }

    func textRange(for range: NSRange) -> NSTextRange? {
        guard let content,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private func offset(of location: any NSTextLocation) -> Int {
        guard let content else { return 0 }
        return content.offset(from: content.documentRange.location, to: location)
    }

    /// Call when the text changed at `location` (layout after it is no longer exact).
    func noteEdit(at location: Int) {
        exactLayoutEnd = min(exactLayoutEnd, max(0, location))
        if cursor != nil { cursorStale = true }
    }

    /// TextKit 2 places text it has not laid out yet at estimated positions,
    /// which move once the text before it is laid out (so `zb`, `H` or `<C-d>`
    /// would land on the wrong line). This lays out everything from the start
    /// of the document up to `range`; only text past what was already laid
    /// out costs anything.
    func ensureExactLayout(through range: NSTextRange) {
        guard let layoutManager, let content else { return }
        let width = layoutManager.textContainer?.size.width ?? 0
        if width != exactLayoutWidth {
            exactLayoutWidth = width
            exactLayoutEnd = 0
        }
        let target = offset(of: range.endLocation)
        if target > exactLayoutEnd,
           let start = content.location(content.documentRange.location, offsetBy: exactLayoutEnd),
           let missing = NSTextRange(location: start, end: range.endLocation) {
            layoutManager.ensureLayout(for: missing)
            exactLayoutEnd = target
        } else {
            layoutManager.ensureLayout(for: range)
        }
    }

    /// Box of the character at `offset`. At a line end (or the end of the
    /// text) it is a `spaceWidth`-wide box.
    func characterRect(at offset: Int, text: NSString, spaceWidth: CGFloat, lineHeight: CGFloat) -> CGRect? {
        guard let layoutManager else { return nil }
        let offset = max(0, min(offset, text.length))
        let isCharacter = offset < text.length && text.character(at: offset) != 0x0A
        let length = isCharacter ? text.rangeOfComposedCharacterSequence(at: offset).length : 0
        guard let range = textRange(for: NSRange(location: offset, length: length)) else { return nil }
        ensureExactLayout(through: range)
        var rect: CGRect?
        layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            rect = rect.map { $0.union(frame) } ?? frame
            return true
        }
        guard var rect else {
            guard text.length == 0 else { return nil }
            let padding = layoutManager.textContainer?.lineFragmentPadding ?? 0
            return CGRect(x: padding, y: 0, width: spaceWidth, height: lineHeight)
        }
        if !isCharacter || rect.width < 1 { rect.size.width = spaceWidth }
        if rect.height < 1 { rect.size.height = lineHeight }
        return rect
    }

    /// Offset of the character at `point`, laying out that part of the text
    /// first. Works outside the laid-out viewport, unlike the text views'
    /// own hit testing.
    func characterIndex(at point: CGPoint, text: NSString) -> Int {
        guard let layoutManager else { return 0 }
        if point.y < 0 { return 0 }
        layoutManager.ensureLayout(for: CGRect(x: 0, y: point.y, width: 1, height: 1))
        guard let fragment = layoutManager.textLayoutFragment(for: point) else { return text.length }
        let frame = fragment.layoutFragmentFrame
        let start = offset(of: fragment.rangeInElement.location)
        let lines = fragment.textLineFragments
        let y = point.y - frame.minY
        guard let line = lines.first(where: { y < $0.typographicBounds.maxY }) ?? lines.last else { return start }
        let bounds = line.typographicBounds
        let lineStart = start + line.characterRange.location
        var lineEnd = min(lineStart + line.characterRange.length, text.length)
        if lineEnd > lineStart, text.character(at: lineEnd - 1) == 0x0A { lineEnd -= 1 }
        let x = point.x - frame.minX - bounds.minX
        if x <= 0 { return lineStart }
        let index = line.characterIndex(for: CGPoint(x: x, y: bounds.height / 2))
        if index == NSNotFound { return lineEnd } // past the end of the line
        return min(max(start + index, lineStart), lineEnd)
    }

    /// Start or end of the screen line (wrapped row) containing `offset`.
    func screenLineBoundary(from offset: Int, forward: Bool, text: NSString) -> Int? {
        guard let layoutManager, let content,
              let location = content.location(content.documentRange.location, offsetBy: offset),
              let fragment = layoutManager.textLayoutFragment(for: location)
        else { return nil }
        let fragmentStart = self.offset(of: fragment.rangeInElement.location)
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

    // MARK: Search highlight and block cursor
    //
    // Both are rendering attributes. The cursor paints its character with the
    // cursor color behind it and the text background color on top (inverted).

    private var highlightRanges: [NSRange] = []
    private var highlightColor: Any?
    private var cursor: (range: NSRange, background: NSObject, foreground: NSObject)?
    /// The text changed since the cursor was drawn; its old range may be stale.
    private var cursorStale = false

    /// The character range the block cursor paints, if any.
    var cursorRange: NSRange? { cursor?.range }

    /// Replaces the search highlight with `ranges`.
    func setHighlights(_ ranges: [NSRange], color: Any) {
        guard let layoutManager else { return }
        highlightRanges = ranges
        highlightColor = color
        layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
        layoutManager.removeRenderingAttribute(.foregroundColor, for: layoutManager.documentRange)
        cursorStale = false
        for match in ranges {
            if let range = textRange(for: match) {
                layoutManager.addRenderingAttribute(.backgroundColor, value: color, for: range)
            }
        }
        applyCursor()
    }

    /// Paints the block cursor over `range` (one character), or removes it.
    func setCursor(_ range: NSRange?, background: NSObject, foreground: NSObject) {
        guard let layoutManager else { return }
        if !cursorStale, let old = cursor, let range, old.range == range,
           old.background.isEqual(background), old.foreground.isEqual(foreground) {
            return
        }
        if cursorStale {
            // Edits may have moved or dropped the old attributes; repaint everything.
            cursor = range.map { ($0, background, foreground) }
            setHighlights(highlightRanges, color: highlightColor ?? NSNull())
            return
        }
        if let old = cursor?.range, let oldRange = textRange(for: old) {
            layoutManager.removeRenderingAttribute(.foregroundColor, for: oldRange)
            layoutManager.removeRenderingAttribute(.backgroundColor, for: oldRange)
            if let highlightColor {
                for match in highlightRanges where NSIntersectionRange(match, old).length > 0 {
                    if let overlap = textRange(for: NSIntersectionRange(match, old)) {
                        layoutManager.addRenderingAttribute(.backgroundColor, value: highlightColor, for: overlap)
                    }
                }
            }
        }
        cursor = range.map { ($0, background, foreground) }
        applyCursor()
    }

    private func applyCursor() {
        guard let layoutManager, let cursor, let range = textRange(for: cursor.range) else { return }
        layoutManager.addRenderingAttribute(.backgroundColor, value: cursor.background, for: range)
        layoutManager.addRenderingAttribute(.foregroundColor, value: cursor.foreground, for: range)
    }
}
