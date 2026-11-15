import CoreText
import Foundation
import Testing
@testable import VimKit

/// VimTextLayout: the row model behind VimKit's own text views.
@MainActor
struct TextLayoutTests {
    let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)

    /// Lines with tabs, Cyrillic, CJK, emoji, combining marks, long runs that
    /// wrap, and blank lines.
    func randomText(lines: Int, seed: UInt64) -> String {
        var generator = SeededGenerator(seed: seed)
        let pieces = ["x", "word ", "\t", "привет ", "漢字", "😀", "e\u{301}", "    ", "(", ")", "{", "}", "averyveryverylongidentifier",
                      " ", "", "a b c d e f g h i j k l m n o p ", "שלום ", "עולם", "مرحبا ", "بالعالم", "abc שלום def "]
        return (0..<lines).map { _ in
            let count = Int.random(in: 0...(Int.random(in: 0...9, using: &generator) == 0 ? 60 : 8), using: &generator)
            return (0..<count).map { _ in pieces.randomElement(using: &generator)! }.joined()
        }.joined(separator: "\n")
    }

    @Test(arguments: [80.0, 200.0, 333.0, 700.0, .infinity])
    func fastPathCountsRowsLikeCoreText(width: Double) {
        let text = NSMutableString(string: randomText(lines: 400, seed: 7))
        let layout = VimTextLayout(text: text, font: font, wrapWidth: width)
        for line in 0..<layout.lineCount {
            let counted = layout.visibleRows(ofLine: line)
            let typeset = layout.line(line).rowCount
            #expect(counted == typeset, "line \(line) at width \(width): \(text.substring(with: NSRange(location: layout.starts[line], length: layout.lineEnd(line) - layout.starts[line])).debugDescription)")
            if counted != typeset { return }
        }
    }

    @Test func incrementalEditsMatchRebuild() {
        var generator = SeededGenerator(seed: 42)
        let inserts = ["", "a", "\n", "x\ny", "\n\n", "long line that wraps around the narrow width for sure, twice over", "\t", "😀", "привет\n"]
        for round in 0..<60 {
            let text = NSMutableString(string: randomText(lines: Int.random(in: 1...80, using: &generator), seed: UInt64(round)))
            let layout = VimTextLayout(text: text, font: font, wrapWidth: 250)
            for step in 0..<30 {
                let length = text.length
                var start = Int.random(in: 0...length, using: &generator)
                var end = min(length, start + Int.random(in: 0...20, using: &generator))
                // Keep surrogate pairs whole, as NSTextStorage edits do.
                if start > 0, start < length, (0xDC00...0xDFFF).contains(text.character(at: start)) { start -= 1 }
                if end > 0, end < length, (0xDC00...0xDFFF).contains(text.character(at: end)) { end += 1 }
                let insert = inserts.randomElement(using: &generator)!
                text.replaceCharacters(in: NSRange(location: start, length: end - start), with: insert)
                let newLength = (insert as NSString).length
                layout.textDidChange(editedRange: NSRange(location: start, length: newLength), changeInLength: newLength - (end - start))
                let fresh = VimTextLayout(text: NSMutableString(string: text), font: font, wrapWidth: 250)
                let same = layout.starts == fresh.starts && layout.rowCount == fresh.rowCount
                    && (0..<fresh.lineCount).allSatisfy { layout.visibleRows(ofLine: $0) == fresh.visibleRows(ofLine: $0) }
                #expect(same, "round \(round) step \(step)")
                if !same { return }
            }
        }
    }

    @Test func characterGeometryRoundTrips() {
        let text = NSMutableString(string: randomText(lines: 300, seed: 3))
        let layout = VimTextLayout(text: text, font: font, wrapWidth: 300)
        var generator = SeededGenerator(seed: 9)
        var checked = 0
        for _ in 0..<2_000 {
            let offset = Int.random(in: 0..<text.length, using: &generator)
            let character = text.character(at: offset)
            guard character != 0x0A, text.rangeOfComposedCharacterSequence(at: offset).location == offset else { continue }
            let rect = layout.characterRect(at: offset)
            #expect(rect.height == layout.rowHeight)
            // A glyph narrower than a point (a tab just before a tab stop) gets
            // a space-wide box for the cursor, overlapping the next one.
            let next = layout.characterRect(at: offset + text.rangeOfComposedCharacterSequence(at: offset).length)
            if next.minY == rect.minY, next.minX > rect.minX, next.minX < rect.maxX - 0.5 { continue }
            let back = layout.characterIndex(at: CGPoint(x: rect.midX, y: rect.midY))
            #expect(back == offset, "offset \(offset) rect \(rect) → \(back)")
            if back != offset { return }
            checked += 1
        }
        #expect(checked > 500)
        // Rows are stacked without gaps.
        var y: CGFloat = 0
        for line in 0..<layout.lineCount {
            #expect(layout.y(ofLine: line) == y)
            y += CGFloat(layout.visibleRows(ofLine: line)) * layout.rowHeight
        }
        #expect(y == layout.height)
    }

    @Test func foldedLinesTakeNoRows() {
        let text = NSMutableString(string: (0..<100).map { "line \($0)" }.joined(separator: "\n"))
        let layout = VimTextLayout(text: text, font: font, wrapWidth: 500)
        let row = layout.rowHeight
        // Hide lines 10...19 and 50...59 (whole lines, as the engine reports folds).
        let first = NSRange(location: layout.starts[10], length: layout.starts[20] - layout.starts[10])
        let second = NSRange(location: layout.starts[50], length: layout.starts[60] - layout.starts[50])
        layout.setHidden([first, second])
        #expect(layout.height == CGFloat(80) * row)
        #expect(layout.y(ofLine: 20) == 10 * row)
        #expect(layout.y(ofLine: 60) == 40 * row)
        #expect(layout.characterIndex(at: CGPoint(x: 1, y: 10 * row + 1)) == layout.starts[20])
        #expect(layout.characterRect(at: layout.starts[15]).minY == 9 * row) // reported on the header line
        // Editing above shifts the folds with the text.
        text.insert("new\n", at: 0)
        layout.textDidChange(editedRange: NSRange(location: 0, length: 4), changeInLength: 4)
        #expect(layout.isHidden(11) && layout.isHidden(20) && !layout.isHidden(21))
        #expect(layout.height == CGFloat(81) * row)
    }

    @Test func largeDocumentIsFast() {
        var lines: [String] = []
        var block = 0
        while lines.count < 20_000 {
            let i = block
            lines += ["func handler\(i)(value: Int) -> Int {", "    let value\(i) = compute(\(i), \"label \(i)\") // note \(i % 97)",
                      "    if value\(i) > \(i % 50) {", "        print(\"item \(i)\", value\(i))", "        total += value\(i) * (\(i) + 1)",
                      "    }", "    var list\(i) = [\(i), \(i + 1), \(i + 2)]", "    return list\(i).count + value\(i)", "}", ""]
            block += 1
        }
        let text = NSMutableString(string: lines.joined(separator: "\n"))
        var start = Date()
        let layout = VimTextLayout(text: text, font: font, wrapWidth: 880)
        let build = Date().timeIntervalSince(start) * 1000
        #expect(layout.height == 20_000 * layout.rowHeight)
        start = Date()
        text.insert("new line\n", at: 0)
        layout.textDidChange(editedRange: NSRange(location: 0, length: 9), changeInLength: 9)
        let rect = layout.characterRect(at: text.length - 3)
        let edit = Date().timeIntervalSince(start) * 1000
        #expect(rect.minY == CGFloat(layout.line(containing: text.length - 3)) * layout.rowHeight)
        #expect(layout.lineCount == 20_001)
        start = Date()
        let whole = NSRange(location: 0, length: text.length)
        let replaced = text.replacingOccurrences(of: "value", with: "item")
        text.replaceCharacters(in: whole, with: replaced)
        layout.textDidChange(editedRange: NSRange(location: 0, length: text.length), changeInLength: text.length - whole.length)
        _ = layout.characterRect(at: text.length - 3)
        let replace = Date().timeIntervalSince(start) * 1000
        print(String(format: "VimTextLayout 20k lines: build %.1f ms, edit at top + rect at end %.2f ms, replace all %.1f ms", build, edit, replace))
        #expect(build < 200)
        #expect(edit < 20)
        #expect(replace < 200)
    }
}

/// Deterministic random numbers for reproducible test text.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
