#if os(macOS)
import AppKit
import Testing
@testable import VimCore
@testable import VimKit

/// End-to-end behaviour of VimTextView in a real window: key events in,
/// text, cursor, scrolling and selection out.
@MainActor
@Suite(.serialized)
struct WindowScenarioTests {
    static func numbered(_ count: Int) -> String {
        (0..<count).map { "line \($0)" }.joined(separator: "\n")
    }

    /// Line of the cursor, from the engine.
    func line(_ editor: EditorWindow) -> Int { editor.view.vim.cursor.line }

    /// First and last logical line on screen, measured the way Vim's H/L do
    /// (small tolerance at the edges) without laying out the whole document.
    func visibleLines(_ editor: EditorWindow) -> ClosedRange<Int> {
        let visible = editor.visibleRect, view = editor.view
        func lineAt(_ y: CGFloat) -> Int {
            let offset = view.characterIndex(at: CGPoint(x: visible.minX + 10, y: y))
            let prefix = (view.string as NSString).substring(to: offset)
            return prefix.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        }
        return lineAt(visible.minY + 6)...lineAt(visible.maxY - 10)
    }

    func cursorIsVisible(_ editor: EditorWindow) -> Bool {
        guard let rect = editor.view.characterRect(at: editor.view.vim.cursorOffset) else { return false }
        return editor.visibleRect.insetBy(dx: 0, dy: -0.5).contains(CGPoint(x: editor.visibleRect.minX + 1, y: rect.midY))
    }

    func inSync(_ editor: EditorWindow) -> Bool { editor.view.string == editor.view.vim.text }

    @Test func editsReachTheView() {
        let editor = EditorWindow(text: Self.numbered(300))
        editor.type("100Gx")
        #expect((editor.view.string as NSString).components(separatedBy: "\n")[99] == "ine 99")
        editor.type("u")
        #expect((editor.view.string as NSString).components(separatedBy: "\n")[99] == "line 99")
        editor.type("ddp")
        #expect((editor.view.string as NSString).components(separatedBy: "\n")[99...100] == ["line 100", "line 99"])
        #expect(inSync(editor))
    }

    @Test func jumpsScrollTheCursorIntoView() {
        let editor = EditorWindow(text: Self.numbered(500))
        editor.type("G")
        #expect(line(editor) == 499)
        #expect(cursorIsVisible(editor))
        editor.type("gg")
        #expect(editor.visibleRect.minY <= 1)
        editor.type("250G")
        #expect(cursorIsVisible(editor))
        editor.type("/line 400<CR>")
        #expect(line(editor) == 400)
        #expect(cursorIsVisible(editor))
    }

    @Test func halfPageAndPageScrolling() {
        let editor = EditorWindow(text: Self.numbered(500))
        let page = visibleLines(editor).count
        #expect(page > 20)
        editor.type("<C-d>")
        let half = line(editor)
        #expect(abs(half - page / 2) <= 2, "C-d moved \(half) lines, page is \(page)")
        #expect(editor.visibleRect.minY > 0)
        #expect(cursorIsVisible(editor))
        editor.type("<C-u>")
        #expect(line(editor) == 0)
        #expect(editor.visibleRect.minY <= 1)
        // As in codemirror-vim: the cursor moves down a page and the view follows it.
        editor.type("<C-f>")
        #expect(abs(line(editor) - page) <= 2, "C-f moved to \(line(editor)), page is \(page)")
        #expect(cursorIsVisible(editor))
        editor.type("<C-b>")
        #expect(visibleLines(editor).lowerBound == 0)
        #expect(cursorIsVisible(editor))
    }

    @Test func screenRelativeMotions() {
        let editor = EditorWindow(text: Self.numbered(500))
        editor.type("200Gzt")
        #expect(visibleLines(editor).lowerBound == 199)
        editor.type("L")
        #expect(line(editor) == visibleLines(editor).upperBound)
        editor.type("H")
        #expect(line(editor) == 199)
        editor.type("M")
        let range = visibleLines(editor)
        #expect(abs(line(editor) - (range.lowerBound + range.upperBound) / 2) <= 1)
        editor.type("zz")
        let centered = visibleLines(editor)
        #expect(abs((centered.lowerBound + centered.upperBound) / 2 - line(editor)) <= 1)
        editor.type("zb")
        #expect(visibleLines(editor).upperBound == line(editor))
        editor.type("<C-e>")
        #expect(cursorIsVisible(editor))
    }

    @Test func wrappedLines() {
        let long = String(repeating: "abcdefghij", count: 40) // 400 chars, wraps in 400 pt
        let editor = EditorWindow(text: "short\n" + long + "\nend", size: NSSize(width: 400, height: 300))
        editor.type("j")
        #expect(line(editor) == 1)
        let start = editor.view.vim.cursor.column
        editor.type("gj")
        let afterGj = editor.view.vim.cursor
        #expect(afterGj.line == 1, "gj stays on the wrapped line")
        #expect(afterGj.column > start + 20)
        editor.type("gk")
        #expect(editor.view.vim.cursor == VimPosition(line: 1, column: start))
        editor.type("g$")
        let rowEnd = editor.view.vim.cursor.column
        #expect(rowEnd > 20 && rowEnd < 399, "g$ ends at the screen row, got \(rowEnd)")
        editor.type("g0")
        #expect(editor.view.vim.cursor.column == 0)
        editor.type("j")
        #expect(line(editor) == 2, "j moves by logical line")
    }

    @Test func visualModeSelectsInTheView() {
        let editor = EditorWindow(text: Self.numbered(50))
        editor.type("3GVjj")
        let selected = editor.view.selectedRange()
        let text = editor.view.string as NSString
        #expect(text.substring(with: selected).hasPrefix("line 2\nline 3\nline 4"))
        editor.type("d")
        #expect(text.length > (editor.view.string as NSString).length)
        #expect((editor.view.string as NSString).components(separatedBy: "\n")[2] == "line 5")
        #expect(inSync(editor))
    }

    @Test func substituteAndUndoKeepTheViewInSync() {
        let editor = EditorWindow(text: Self.numbered(2_000))
        editor.type(":%s/line/row/g<CR>")
        #expect(editor.view.string.hasPrefix("row 0\nrow 1"))
        #expect(inSync(editor))
        editor.type("u")
        #expect(editor.view.string == Self.numbered(2_000))
        editor.type("<C-r>")
        #expect(editor.view.string.hasPrefix("row 0"))
        #expect(inSync(editor))
    }

    @Test func blockCursorFollowsTheCursor() {
        let editor = EditorWindow(text: Self.numbered(50))
        editor.type("5Gw")
        let cursorView = editor.view.subviews.first { !$0.isHidden && $0.frame.width < 30 }
        let expected = editor.view.characterRect(at: editor.view.vim.cursorOffset)
        #expect(cursorView != nil)
        if let cursorView, let expected {
            #expect(abs(cursorView.frame.midY - expected.midY) < 2)
            #expect(abs(cursorView.frame.minX - expected.minX) < 2)
        }
        editor.type("i")
        #expect(editor.view.subviews.allSatisfy { $0.isHidden || $0.frame.width >= 30 }, "no block cursor in insert mode")
    }

    @Test func insertModeTypingAndRepeat() {
        let editor = EditorWindow(text: "one\ntwo\nthree")
        editor.type("A")
        editor.view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.type("<Esc>j.")
        #expect(editor.view.string == "one!\ntwo!\nthree")
        editor.type("0ciwTWO<Esc>")
        #expect(editor.view.string == "one!\nTWO!\nthree")
        #expect(inSync(editor))
    }
}
#endif
