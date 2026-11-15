import CoreText
import Foundation

/// Exact vertical layout of a document for VimKit's own text views.
///
/// Every screen row has the same height (a code editor's monospaced grid), so
/// the position of any line is "screen rows before it × row height". Each line
/// knows how many screen rows it wraps to; most lines fit and are counted from
/// glyph advances without typesetting, longer ones are typeset with CoreText.
/// Rows are summed in a Fenwick tree, so `y ↔ line` lookups and edits cost
/// O(log lines), and the document height is always exact — unlike TextKit 2,
/// which estimates the height of text away from the screen and re-estimates
/// it while scrolling.
///
/// Coordinates: x from the left edge of the text, y from the top of the first
/// row. Offsets are UTF-16, as in `NSString`.
@MainActor
final class VimTextLayout {
    /// One line laid out into screen rows.
    final class Line {
        let typesetter: CTTypesetter
        /// UTF-16 length without the line break.
        let length: Int
        /// Where each screen row starts, as offsets within the line.
        let rowStarts: [Int]
        private var lines: [CTLine?]

        init(typesetter: CTTypesetter, length: Int, rowStarts: [Int]) {
            self.typesetter = typesetter
            self.length = length
            self.rowStarts = rowStarts
            lines = Array(repeating: nil, count: rowStarts.count)
        }

        var rowCount: Int { rowStarts.count }

        /// Offsets of row `row` within the line (the last row ends at the line end).
        func rowRange(_ row: Int) -> Range<Int> {
            rowStarts[row]..<(row + 1 < rowStarts.count ? rowStarts[row + 1] : length)
        }

        /// The row showing the character at `column`; a column on a wrap
        /// boundary belongs to the row it starts.
        func row(containing column: Int) -> Int {
            var lo = 0, hi = rowStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if rowStarts[mid] <= column { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }

        func ctLine(row: Int) -> CTLine {
            if let line = lines[row] { return line }
            let range = rowRange(row)
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.lowerBound, length: range.count))
            lines[row] = line
            return line
        }

        /// x of the caret before `column` (within its row).
        func x(at column: Int) -> CGFloat {
            let row = row(containing: column)
            return CTLineGetOffsetForStringIndex(ctLine(row: row), column, nil)
        }
    }

    // MARK: Metrics

    private(set) var font: CTFont
    /// Columns per tab stop.
    private(set) var tabWidth: Int
    /// Width rows wrap at, or `.infinity` for no wrapping.
    private(set) var wrapWidth: CGFloat
    private(set) var rowHeight: CGFloat = 16
    /// Distance from the top of a row to the baseline.
    private(set) var baseline: CGFloat = 12
    /// Advance of a space: the width of an empty cell (line ends, cursor box).
    private(set) var spaceWidth: CGFloat = 8
    private var tabInterval: CGFloat = 32
    private var paragraphStyle: CTParagraphStyle?
    /// Advance of each BMP character in `font`: -1 not looked up yet, -2 needs
    /// typesetting (missing glyph, control character, surrogate).
    private var advances = [Float](repeating: -1, count: 0x10000)

    // MARK: Lines

    /// The text being laid out; read only.
    let text: NSMutableString
    /// UTF-16 offset where each line starts.
    private(set) var starts: [Int] = [0]
    /// Screen rows of each line, ignoring folds.
    private var rows: [Int32] = [1]
    /// Lines hidden by closed folds, sorted, not overlapping.
    private(set) var hiddenLines: [ClosedRange<Int>] = []
    /// Visible rows per line (0 when hidden), summed.
    private var tree = Fenwick()
    private var cache: [Int: Line] = [:]

    init(text: NSMutableString, font: CTFont, tabWidth: Int = 4, wrapWidth: CGFloat = .infinity) {
        self.text = text
        self.font = font
        self.tabWidth = max(1, tabWidth)
        self.wrapWidth = wrapWidth
        updateMetrics()
        rebuild()
    }

    var lineCount: Int { starts.count }
    var rowCount: Int { tree.total }
    var height: CGFloat { CGFloat(tree.total) * rowHeight }

    func setFont(_ font: CTFont) {
        guard !CFEqual(font, self.font) else { return }
        self.font = font
        updateMetrics()
        rebuild()
    }

    func setTabWidth(_ width: Int) {
        guard max(1, width) != tabWidth else { return }
        tabWidth = max(1, width)
        updateMetrics()
        rebuild()
    }

    func setWrapWidth(_ width: CGFloat) {
        let width = width > 0 ? width : .infinity
        guard width != wrapWidth else { return }
        wrapWidth = width
        cache = [:]
        recountRows()
    }

    private func updateMetrics() {
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        rowHeight = max(1, ceil(ascent + descent + leading))
        baseline = (rowHeight - (ascent + descent)) / 2 + ascent
        spaceWidth = advance(of: 0x20) ?? CTFontGetSize(font) * 0.6
        tabInterval = spaceWidth * CGFloat(tabWidth)
        var interval = tabInterval
        let stops = [CTTextTab]() as CFArray
        paragraphStyle = withUnsafePointer(to: &interval) { intervalPointer in
            withUnsafePointer(to: stops) { stopsPointer in
                let settings = [
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size,
                                            value: intervalPointer),
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: stopsPointer),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        advances = [Float](repeating: -1, count: 0x10000)
    }

    /// Attributes every line is laid out with.
    var attributes: [NSAttributedString.Key: Any] {
        // Drawn in the context's fill color, so one laid-out line serves any
        // text color (and the inverted character under the block cursor).
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if let paragraphStyle { attributes[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = paragraphStyle }
        return attributes
    }

    private func advance(of unit: UInt16) -> CGFloat? {
        let cached = advances[Int(unit)]
        if cached >= 0 { return CGFloat(cached) }
        if cached == -2 { return nil }
        var result: Float = -2
        if unit >= 0x20, unit != 0x7F, !(0xD800...0xDFFF).contains(unit) {
            var character = unit, glyph = CGGlyph(0)
            if CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 {
                var size = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &size, 1)
                result = Float(size.width)
            }
        }
        advances[Int(unit)] = result
        return result >= 0 ? CGFloat(result) : nil
    }

    // MARK: Building

    /// Re-reads all of the text.
    func rebuild() {
        widest = nil
        let length = text.length
        indexedLength = length
        var buffer = [UInt16](repeating: 0, count: length)
        if length > 0 { text.getCharacters(&buffer, range: NSRange(location: 0, length: length)) }
        var starts = [0]
        starts.reserveCapacity(length / 32 + 1)
        for i in 0..<length where buffer[i] == 0x0A { starts.append(i + 1) }
        self.starts = starts
        cache = [:]
        rows = buffer.withUnsafeBufferPointer { units in
            (0..<starts.count).map { line in
                let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
                return rowCount(line: line, units: UnsafeBufferPointer(rebasing: units[starts[line]..<end]))
            }
        }
        hiddenLines = hiddenLines.filter { $0.upperBound < starts.count }
        rebuildTree()
    }

    private func recountRows() {
        let length = text.length
        var buffer = [UInt16](repeating: 0, count: length)
        if length > 0 { text.getCharacters(&buffer, range: NSRange(location: 0, length: length)) }
        rows = buffer.withUnsafeBufferPointer { units in
            (0..<starts.count).map { line in
                rowCount(line: line, units: UnsafeBufferPointer(rebasing: units[starts[line]..<lineEnd(line)]))
            }
        }
        rebuildTree()
    }

    private func rebuildTree() {
        var values = rows.map(Int.init)
        for range in hiddenLines { for line in range { values[line] = 0 } }
        tree = Fenwick(values)
    }

    /// Screen rows of a line: 1 when it fits (measured from advances),
    /// otherwise typeset.
    private func rowCount(line: Int, units: UnsafeBufferPointer<UInt16>) -> Int32 {
        guard wrapWidth.isFinite else { return 1 }
        var x: CGFloat = 0
        var simple = true
        for unit in units {
            if unit == 0x09 {
                x = (floor(x / tabInterval + 0.001) + 1) * tabInterval
            } else if let advance = advance(of: unit) {
                x += advance
            } else {
                simple = false
                break
            }
            if x > wrapWidth { simple = false; break }
        }
        if simple, x <= wrapWidth - 0.5 { return 1 }
        return Int32(layout(line: line, units: units).rowCount)
    }

    /// Lays out a line (cached).
    func line(_ line: Int) -> Line {
        if let cached = cache[line] { return cached }
        let range = NSRange(location: starts[line], length: lineEnd(line) - starts[line])
        var units = [UInt16](repeating: 0, count: range.length)
        if range.length > 0 { text.getCharacters(&units, range: range) }
        return units.withUnsafeBufferPointer { layout(line: line, units: $0) }
    }

    private func layout(line: Int, units: UnsafeBufferPointer<UInt16>) -> Line {
        if let cached = cache[line] { return cached }
        // CFString keeps the UTF-16 units as they are (a Swift String would
        // repair lone surrogates and shift offsets).
        let string = CFStringCreateWithCharacters(nil, units.baseAddress, units.count)!
        let attributed = CFAttributedStringCreate(nil, string, attributes as CFDictionary)!
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var rowStarts = [0]
        if wrapWidth.isFinite {
            var start = 0
            while true {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(wrapWidth))
                if count <= 0 || start + count >= units.count { break }
                start += count
                rowStarts.append(start)
            }
        }
        let result = Line(typesetter: typesetter, length: units.count, rowStarts: rowStarts)
        if cache.count > 2_048 { cache = [:] }
        cache[line] = result
        return result
    }

    // MARK: Editing

    /// Call after the text changed: `editedRange` is in the new text,
    /// `changeInLength` is new length − old length (`NSTextStorage` terms).
    func textDidChange(editedRange: NSRange, changeInLength delta: Int) {
        let newLength = text.length
        guard editedRange.location != NSNotFound, editedRange.upperBound <= newLength,
              newLength - delta == indexedLength else {
            rebuild()
            return
        }
        let oldLength = indexedLength
        let first = line(containing: editedRange.location)
        let last = line(containing: editedRange.upperBound - delta)
        // The new text of lines first...last (without the line break after them).
        let regionStart = starts[first]
        let regionEnd = (last + 1 < starts.count ? starts[last + 1] - 1 : oldLength) + delta
        var units = [UInt16](repeating: 0, count: regionEnd - regionStart)
        if !units.isEmpty { text.getCharacters(&units, range: NSRange(location: regionStart, length: units.count)) }
        var newStarts = [regionStart]
        for (i, unit) in units.enumerated() where unit == 0x0A { newStarts.append(regionStart + i + 1) }
        let oldCount = last - first + 1, lineDelta = newStarts.count - oldCount

        starts.replaceSubrange(first...last, with: newStarts)
        if delta != 0 { for i in (first + newStarts.count)..<starts.count { starts[i] += delta } }
        indexedLength = newLength

        // Cached lines move with the text; the edited ones are laid out again.
        var moved: [Int: Line] = [:]
        for (line, layout) in cache where line < first || line > last {
            moved[line > last ? line + lineDelta : line] = layout
        }
        cache = moved
        let newRows: [Int32] = units.withUnsafeBufferPointer { buffer in
            (0..<newStarts.count).map { k in
                let start = newStarts[k] - regionStart
                let end = k + 1 < newStarts.count ? newStarts[k + 1] - 1 - regionStart : units.count
                return rowCount(line: first + k, units: UnsafeBufferPointer(rebasing: buffer[start..<end]))
            }
        }
        rows.replaceSubrange(first...last, with: newRows)
        // The widest line only grows on edits (as in NSTextView); shrinking
        // waits for the next full measure.
        if let known = widest {
            widest = units.withUnsafeBufferPointer { buffer -> CGFloat? in
                var result = known
                for k in 0..<newStarts.count {
                    let start = newStarts[k] - regionStart
                    let end = k + 1 < newStarts.count ? newStarts[k + 1] - 1 - regionStart : units.count
                    guard let width = fastWidth(UnsafeBufferPointer(rebasing: buffer[start..<end])) else { return nil }
                    result = max(result, width)
                }
                return result
            }
        }

        if !hiddenLines.isEmpty {
            hiddenLines = hiddenLines.compactMap { range in
                if range.upperBound < first { return range }
                if range.lowerBound > last { return (range.lowerBound + lineDelta)...(range.upperBound + lineDelta) }
                return nil // the engine sends the folds again after edits
            }
        }
        if lineDelta == 0 && hiddenLines.isEmpty {
            for k in 0..<newRows.count {
                let line = first + k
                tree.add(line, Int(newRows[k]) - tree.value(line))
            }
        } else {
            rebuildTree()
        }
    }

    /// Length of the text the line index describes.
    private var indexedLength = 0

    private var widest: CGFloat?

    /// Width of a line from glyph advances, or nil when it needs typesetting.
    private func fastWidth(_ units: UnsafeBufferPointer<UInt16>) -> CGFloat? {
        var x: CGFloat = 0
        for unit in units {
            if unit == 0x09 {
                x = (floor(x / tabInterval + 0.001) + 1) * tabInterval
            } else if let advance = advance(of: unit) {
                x += advance
            } else {
                return nil
            }
        }
        return x
    }

    /// Width of the widest line, for horizontal scrolling without wrapping.
    /// Measured from glyph advances; lines that need typesetting are typeset.
    func widestLineWidth() -> CGFloat {
        if let widest { return widest }
        let length = text.length
        var buffer = [UInt16](repeating: 0, count: length)
        if length > 0 { text.getCharacters(&buffer, range: NSRange(location: 0, length: length)) }
        var result: CGFloat = 0
        buffer.withUnsafeBufferPointer { units in
            for line in 0..<starts.count {
                let x = fastWidth(UnsafeBufferPointer(rebasing: units[starts[line]..<lineEnd(line)])) ?? {
                    let layout = self.line(line)
                    return (0..<layout.rowCount).map { CGFloat(CTLineGetTypographicBounds(layout.ctLine(row: $0), nil, nil, nil)) }.max() ?? 0
                }()
                result = max(result, x)
            }
        }
        widest = result
        return result
    }

    // MARK: Folds

    /// Hides the lines that `ranges` (whole lines, UTF-16) cover.
    func setHidden(_ ranges: [NSRange]) {
        var lines: [ClosedRange<Int>] = []
        for range in ranges where range.length > 0 {
            let first = line(containing: range.location)
            let last = line(containing: max(range.location, range.upperBound - 1))
            if let previous = lines.last, previous.upperBound >= first - 1 {
                lines[lines.count - 1] = previous.lowerBound...max(previous.upperBound, last)
            } else {
                lines.append(first...last)
            }
        }
        guard lines != hiddenLines else { return }
        hiddenLines = lines
        rebuildTree()
    }

    func isHidden(_ line: Int) -> Bool {
        var lo = 0, hi = hiddenLines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, range = hiddenLines[mid]
            if line < range.lowerBound { hi = mid - 1 } else if line > range.upperBound { lo = mid + 1 } else { return true }
        }
        return false
    }

    // MARK: Queries

    func lineEnd(_ line: Int) -> Int {
        line + 1 < starts.count ? starts[line + 1] - 1 : text.length
    }

    func line(containing offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Top of the line's first row.
    func y(ofLine line: Int) -> CGFloat {
        CGFloat(tree.prefix(line)) * rowHeight
    }

    /// Visible rows of the line (0 when folded away).
    func visibleRows(ofLine line: Int) -> Int { tree.value(line) }

    /// The visible line and its row at document row `row` (clamped).
    func location(ofRow row: Int) -> (line: Int, row: Int) {
        guard tree.total > 0 else { return (0, 0) }
        let row = max(0, min(row, tree.total - 1))
        let line = tree.lineContaining(row: row)
        return (line, row - tree.prefix(line))
    }

    /// Visible lines that intersect `minY..<maxY`, each with its top.
    func visibleLines(from minY: CGFloat, to maxY: CGFloat) -> [(line: Int, y: CGFloat)] {
        guard tree.total > 0, maxY > 0 else { return [] }
        var line = location(ofRow: Int(max(0, minY) / rowHeight)).line
        var y = CGFloat(tree.prefix(line)) * rowHeight
        var result: [(Int, CGFloat)] = []
        while line < starts.count, y < maxY {
            let count = tree.value(line)
            if count > 0 {
                result.append((line, y))
                y += CGFloat(count) * rowHeight
            }
            line += 1
        }
        return result
    }

    /// Box of the character at `offset`; at a line end (or the end of the
    /// text) it is a space-wide box. Lines hidden by folds report the row
    /// of the visible line above them.
    func characterRect(at offset: Int) -> CGRect {
        let offset = max(0, min(offset, text.length))
        var lineIndex = line(containing: offset)
        var column = offset - starts[lineIndex]
        if tree.value(lineIndex) == 0 {
            // Folded away: the end of the nearest visible line above.
            while lineIndex > 0, tree.value(lineIndex) == 0 { lineIndex -= 1 }
            column = lineEnd(lineIndex) - starts[lineIndex]
        }
        let layout = line(lineIndex)
        column = min(column, layout.length)
        let row = layout.row(containing: column)
        let range = layout.rowRange(row)
        let ctLine = layout.ctLine(row: row)
        let x = CTLineGetOffsetForStringIndex(ctLine, column, nil)
        var width = spaceWidth
        if column < range.upperBound {
            let next = min(column + characterLength(at: starts[lineIndex] + column), range.upperBound)
            let measured = CTLineGetOffsetForStringIndex(ctLine, next, nil) - x
            if measured >= 1 { width = measured }
        }
        let y = (CGFloat(tree.prefix(lineIndex)) + CGFloat(row)) * rowHeight
        return CGRect(x: x, y: y, width: width, height: rowHeight)
    }

    private func characterLength(at offset: Int) -> Int {
        guard offset < text.length else { return 1 }
        return text.rangeOfComposedCharacterSequence(at: offset).length
    }

    /// Offset of the character under `point`: the one whose box contains x,
    /// clamped to the row (a row's line break is never returned).
    func characterIndex(at point: CGPoint) -> Int {
        if point.y < 0 || tree.total == 0 { return 0 }
        let documentRow = Int(point.y / rowHeight)
        if documentRow >= tree.total { return text.length }
        let (lineIndex, row) = location(ofRow: documentRow)
        let layout = line(lineIndex)
        let range = layout.rowRange(row)
        let start = starts[lineIndex]
        if point.x <= 0 || range.isEmpty { return start + range.lowerBound }
        let ctLine = layout.ctLine(row: row)
        var column = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: point.x, y: 0))
        if column == kCFNotFound { column = range.upperBound }
        column = max(range.lowerBound, min(column, range.upperBound))
        // Nearest boundary → the character containing x.
        if column > range.lowerBound, CTLineGetOffsetForStringIndex(ctLine, column, nil) > point.x { column -= 1 }
        let isLastRow = row == layout.rowCount - 1
        if column >= range.upperBound {
            column = isLastRow ? range.upperBound : max(range.lowerBound, range.upperBound - 1)
        }
        // Inside a composed character: its start.
        var offset = start + column
        if offset < text.length { offset = text.rangeOfComposedCharacterSequence(at: offset).location }
        return offset
    }

    /// Start (or end) of the screen row containing `offset`. A wrapped row
    /// ends where the next one starts; the last row ends before the break.
    func screenLineBoundary(from offset: Int, forward: Bool) -> Int {
        let offset = max(0, min(offset, text.length))
        let lineIndex = line(containing: offset)
        let layout = line(lineIndex)
        let row = layout.row(containing: min(offset - starts[lineIndex], layout.length))
        let range = layout.rowRange(row)
        return starts[lineIndex] + (forward ? range.upperBound : range.lowerBound)
    }
}

/// Prefix sums over per-line row counts.
struct Fenwick {
    private var tree: [Int] = [0]
    private var values: [Int] = []

    init() {}

    init(_ values: [Int]) {
        self.values = values
        var tree = [0] + values
        let n = values.count
        if n > 0 {
            for i in 1...n {
                let parent = i + (i & -i)
                if parent <= n { tree[parent] += tree[i] }
            }
        }
        self.tree = tree
        total = values.reduce(0, +)
    }

    var count: Int { values.count }
    private(set) var total = 0

    func value(_ index: Int) -> Int { values[index] }

    /// Sum of the first `count` values.
    func prefix(_ count: Int) -> Int {
        var i = min(count, values.count), sum = 0
        while i > 0 {
            sum += tree[i]
            i -= i & -i
        }
        return sum
    }

    mutating func add(_ index: Int, _ delta: Int) {
        guard delta != 0 else { return }
        values[index] += delta
        total += delta
        var i = index + 1
        while i < tree.count {
            tree[i] += delta
            i += i & -i
        }
    }

    /// The index whose values contain `row`: prefix(index) <= row < prefix(index + 1).
    func lineContaining(row: Int) -> Int {
        var position = 0, remaining = row
        var step = 1
        while step * 2 <= values.count { step *= 2 }
        while step > 0 {
            let next = position + step
            if next <= values.count, tree[next] <= remaining {
                position = next
                remaining -= tree[next]
            }
            step /= 2
        }
        return position
    }
}
