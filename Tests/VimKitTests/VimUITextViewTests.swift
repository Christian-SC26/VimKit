#if canImport(UIKit) && !os(watchOS)
import Testing
import UIKit
@testable import VimKit

@MainActor
private func makeView(_ text: String, size: CGSize = CGSize(width: 600, height: 400)) -> (UIWindow, VimUITextView) {
    let runtime = VimRuntime()
    runtime.clipboard = InMemoryClipboard()
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    let view = VimUITextView(frame: window.bounds, options: VimOptions(), runtime: runtime)
    window.addSubview(view)
    window.isHidden = false
    view.text = text
    view.selectedRange = NSRange(location: 0, length: 0)
    view.layoutIfNeeded()
    return (window, view)
}

/// Types keys in Vim notation through the same path hardware keys take.
@MainActor
private func type(_ view: VimUITextView, _ keys: String) {
    var index = keys.startIndex
    while index < keys.endIndex {
        if keys[index] == "<", let close = keys[index...].firstIndex(of: ">") {
            let name = String(keys[keys.index(after: index)..<close])
            let named = ["Esc": VimKeyEvent.escape, "CR": VimKeyEvent.enter, "BS": VimKeyEvent.backspace]
            if let key = named[name] {
                view.handleVimKey(VimKeyEvent(key: key))
            } else if name.hasPrefix("C-"), let last = name.last {
                view.handleVimKey(VimKeyEvent(key: String(last), control: true))
            }
            index = keys.index(after: close)
            continue
        }
        let key = VimKeyEvent(key: String(keys[index]))
        if !view.handleVimKey(key) { view.insertText(key.key) } // insert mode: UIKit types it
        index = keys.index(after: index)
    }
}

@MainActor
private func numbered(_ count: Int) -> String {
    (0..<count).map { "line \($0)" }.joined(separator: "\n")
}

@MainActor
@Suite(.serialized)
struct VimUITextViewTests {
    @Test func usesTextKit2() {
        let (_, view) = makeView("abc")
        #expect(view.textLayoutManager != nil)
    }

    @Test func normalModeCommandsEditTheView() {
        let (_, view) = makeView("hello world\nsecond")
        type(view, "dw")
        #expect(view.text == "world\nsecond")
        type(view, "jdd")
        #expect(view.text == "world")
        type(view, "u")
        #expect(view.text == "world\nsecond")
        #expect(view.vim.text == view.text)
    }

    @Test func insertModeTypingReachesTheEngine() {
        let (_, view) = makeView("ab")
        type(view, "a")
        #expect(view.vim.mode == .insert)
        view.insertText("XY")
        #expect(view.text == "aXYb")
        #expect(view.vim.text == "aXYb")
        type(view, "<Esc>")
        #expect(view.vim.mode == .normal)
        type(view, "u")
        #expect(view.text == "ab")
    }

    @Test func dotRepeatsAnInsert() {
        let (_, view) = makeView("one\ntwo\nthree")
        type(view, "A!<Esc>j.")
        #expect(view.text == "one!\ntwo!\nthree")
    }

    @Test func onScreenKeyboardRunsCommandsInNormalMode() {
        let (_, view) = makeView("abc def")
        view.insertText("dw") // two key taps on the software keyboard
        #expect(view.text == "def")
        view.insertText("i")
        #expect(view.vim.mode == .insert)
        view.insertText("x")
        #expect(view.text == "xdef")
        view.deleteBackward()
        #expect(view.text == "def")
        #expect(view.vim.text == "def")
    }

    @Test func visualSelectionIsShownInTheView() {
        let (_, view) = makeView("abcdef")
        type(view, "vll")
        #expect(view.selectedRange == NSRange(location: 0, length: 3))
        type(view, "d")
        #expect(view.text == "def")
    }

    @Test func tappingMovesTheVimCursor() {
        let (_, view) = makeView("one two")
        view.selectedRange = NSRange(location: 4, length: 0)
        #expect(view.vim.cursorOffset == 4)
        type(view, "x")
        #expect(view.text == "one wo")
    }

    @Test func directTextStorageEditsReachTheEngine() async {
        let (_, view) = makeView("abc")
        view.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "Z")
        await Task.yield()
        #expect(view.vim.text == "Zbc")
    }

    @Test func settingTextResetsTheEngine() {
        let (_, view) = makeView("first")
        view.text = "second text"
        #expect(view.vim.text == "second text")
    }

    @Test func jumpsScrollTheCursorIntoView() throws {
        let (_, view) = makeView(numbered(500))
        type(view, "G")
        #expect(view.vim.cursor.line == 499)
        let rect = try #require(view.characterRect(at: view.vim.cursorOffset))
        #expect(view.bounds.contains(CGPoint(x: view.bounds.midX, y: rect.midY)), "cursor \(rect) not in \(view.bounds)")
        type(view, "gg")
        #expect(view.contentOffset.y <= 1)
    }

    @Test func halfPageScrolling() throws {
        let (_, view) = makeView(numbered(500))
        type(view, "<C-d>")
        let line = view.vim.cursor.line
        #expect(line > 5)
        #expect(view.contentOffset.y > 0)
        type(view, "<C-u>")
        #expect(view.vim.cursor.line == 0)
    }

    @Test func screenRelativeMotions() throws {
        let (_, view) = makeView(numbered(500))
        type(view, "200Gzt")
        let top = try #require(view.characterRect(at: view.vim.cursorOffset))
        #expect(abs(top.minY - view.contentOffset.y - view.adjustedContentInset.top - view.textContainerInset.top) < 20)
        type(view, "L")
        #expect(view.vim.cursor.line > 210)
        type(view, "H")
        #expect(view.vim.cursor.line == 199)
    }

    @Test func wrappedLinesMoveByScreenRow() {
        let long = String(repeating: "abcdefghij", count: 40)
        let (_, view) = makeView("short\n" + long + "\nend", size: CGSize(width: 300, height: 400))
        type(view, "j")
        type(view, "gj")
        #expect(view.vim.cursor.line == 1)
        #expect(view.vim.cursor.column > 20)
        type(view, "j")
        #expect(view.vim.cursor.line == 2)
    }

    @Test func substituteKeepsTheViewInSync() {
        let (_, view) = makeView(numbered(2_000))
        type(view, ":%s/line/row/g<CR>")
        #expect(view.text.hasPrefix("row 0\nrow 1"))
        #expect(view.vim.text == view.text)
        type(view, "u")
        #expect(view.text == numbered(2_000))
    }

    @Test func blockCursorOnlyOutsideInsertMode() {
        let (_, view) = makeView("abc")
        type(view, "l")
        #expect(view.blockCursorFrame != nil)
        #expect(view.tintColor == .clear)
        type(view, "i")
        #expect(view.blockCursorFrame == nil)
        #expect(view.tintColor != .clear)
    }

    @Test func disabledViewIsPlainTextView() {
        let (_, view) = makeView("abc")
        view.isVimEnabled = false
        view.insertText("Z")
        #expect(view.text == "Zabc")
        view.isVimEnabled = true
        #expect(view.vim.text == "Zabc")
    }
}
#endif
