#if os(macOS)
import AppKit
import Testing
@testable import VimCore
@testable import VimKit

/// The line number column: `:set nu`, `:set rnu`, folds, clicks.
@MainActor
@Suite(.serialized)
struct LineNumberTests {
    static let text = (1...200).map { "line \($0)" }.joined(separator: "\n")

    @Test func setNumberShowsTheColumn() throws {
        let editor = EditorWindow(text: Self.text, size: NSSize(width: 500, height: 300))
        let view = editor.view
        #expect(view.lineNumbers == .off)
        #expect(!editor.scrollView.rulersVisible)
        editor.type(":set nu<CR>")
        #expect(view.lineNumbers == .absolute)
        #expect(editor.scrollView.rulersVisible)
        let ruler = try #require(view.lineNumberRuler)
        #expect(ruler.ruleThickness == view.lineNumberWidth())
        #expect(view.lineNumberWidth() > 0)
        let textLeft = view.convert(NSPoint(x: view.textVisibleRect.minX, y: 0), to: editor.scrollView).x
        #expect(textLeft == ruler.ruleThickness, "the text starts right of the numbers")
        #expect(view.frame.width == 500 - ruler.ruleThickness, "and wraps before the window edge")
        editor.type(":set rnu<CR>")
        #expect(view.lineNumbers == .hybrid)
        editor.type(":set nonu<CR>")
        #expect(view.lineNumbers == .relative)
        editor.type(":set nornu<CR>")
        #expect(view.lineNumbers == .off)
        #expect(!editor.scrollView.rulersVisible)
        // Setting it from the app updates vim's options.
        view.lineNumbers = .hybrid
        #expect(view.vim.vimOption("number") as? Bool == true)
        #expect(view.vim.vimOption("relativenumber") as? Bool == true)
    }

    @Test func labelsFollowTheCursorAndSkipFolds() {
        let editor = EditorWindow(text: Self.text)
        let view = editor.view
        view.lineNumbers = .absolute
        #expect(view.lineNumberLabel(0, cursorLine: 0) == "1")
        #expect(view.lineNumberLabel(41, cursorLine: 0) == "42")
        view.lineNumbers = .relative
        editor.type("10G")
        let cursor = view.layout.line(containing: view.vim.status.cursorOffset)
        #expect(cursor == 9)
        #expect(view.lineNumberLabel(9, cursorLine: cursor) == "0")
        #expect(view.lineNumberLabel(12, cursorLine: cursor) == "3")
        #expect(view.lineNumberLabel(4, cursorLine: cursor) == "5")
        view.lineNumbers = .hybrid
        #expect(view.lineNumberLabel(9, cursorLine: cursor) == "10")
        // Fold lines 12-15 (one closed fold counts as one line, as j does).
        editor.type("12Gzf3jzc10G")
        #expect(view.lineNumberLabel(15, cursorLine: cursor) == "3")
        editor.type("3j")
        #expect(view.layout.line(containing: view.vim.status.cursorOffset) == 15, "3j lands on the line numbered 3")
    }

    @Test func columnWidthGrowsWithTheLineCount() {
        let editor = EditorWindow(text: "a\nb")
        let view = editor.view
        view.lineNumbers = .absolute
        let small = view.lineNumberWidth()
        editor.type(":set nuw=1<CR>")
        #expect(view.lineNumberWidth() < small, "numberwidth is the minimum")
        view.string = (1...12_000).map(String.init).joined(separator: "\n")
        #expect(view.lineNumberWidth() > small, "five digits")
        #expect(view.lineNumberRuler?.ruleThickness == view.lineNumberWidth())
    }

    @Test func clickingANumberMovesToItsLine() throws {
        let editor = EditorWindow(text: Self.text, size: NSSize(width: 500, height: 300))
        let view = editor.view
        view.lineNumbers = .absolute
        let ruler = try #require(view.lineNumberRuler)
        let rowY = view.textOrigin.y + view.layout.y(ofLine: 5) + view.lineHeight / 2
        let point = view.convert(NSPoint(x: 0, y: rowY), to: ruler)
        #expect(view.numberedLine(at: NSPoint(x: 10, y: point.y), in: ruler) == 5)
        view.selectLines(5, 5, extending: false)
        #expect(view.layout.line(containing: view.vim.status.cursorOffset) == 5)
        view.selectLines(5, 3, extending: true)
        #expect(view.selectedRange() == NSRange(location: view.layout.starts[3], length: view.layout.starts[6] - view.layout.starts[3]))
    }

    @Test func cursorLineFollowsTheCursor() throws {
        let long = String(repeating: "word ", count: 60)
        let editor = EditorWindow(text: "one\n\(long)\nthree", size: NSSize(width: 400, height: 300))
        let view = editor.view
        #expect(view.cursorLineRect == nil)
        editor.type(":set cul<CR>")
        #expect(view.highlightsCursorLine)
        let first = try #require(view.cursorLineRect)
        #expect(first.minY == view.textOrigin.y && first.height == view.lineHeight && first.width == view.bounds.width)
        editor.type("j")
        let wrapped = try #require(view.cursorLineRect)
        #expect(wrapped.height == CGFloat(view.layout.visibleRows(ofLine: 1)) * view.lineHeight, "all rows of a wrapped line")
        #expect(wrapped.height > view.lineHeight)
        editor.type(":set culopt=screenline<CR>$")
        let screen = try #require(view.cursorLineRect)
        #expect(screen.height == view.lineHeight && screen.minY > wrapped.minY, "only the cursor's row")
        editor.type(":set culopt=number<CR>")
        #expect(view.cursorLineRect == nil && view.highlightsCursorLineNumber, "number only")
        editor.type(":set culopt=line nocul<CR>")
        #expect(view.cursorLineRect == nil && !view.highlightsCursorLineNumber)
        view.highlightsCursorLine = true
        #expect(view.vim.vimOption("cursorline") as? Bool == true)
        #expect(view.cursorLineRect != nil && !view.highlightsCursorLineNumber, "culopt=line: the text, not the number")
    }
}
#endif
